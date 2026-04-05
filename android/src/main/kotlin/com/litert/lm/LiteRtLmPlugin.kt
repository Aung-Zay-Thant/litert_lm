package com.litert.lm

import android.content.Context
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback
import com.google.ai.edge.litertlm.SamplerConfig
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class LiteRtLmPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context

    private var engine: Engine? = null
    private var conversation: Conversation? = null
    private var currentModelPath: String? = null
    private var eventSink: EventChannel.EventSink? = null
    private var benchmarkEnabled = false

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, "litert_lm/method")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "litert_lm/stream")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        conversation?.close()
        engine?.close()
        conversation = null
        engine = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareModel" -> handlePrepareModel(call, result)
            "generateTextStream" -> handleGenerateStream(call, result)
            "cancelGeneration" -> handleCancel(result)
            "resetConversation" -> handleReset(result)
            "getBenchmarkInfo" -> handleGetBenchmark(result)
            else -> result.notImplemented()
        }
    }

    private fun parseBackend(name: String?): Backend {
        return when (name) {
            "gpu" -> Backend.GPU()
            else -> Backend.CPU()
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun handlePrepareModel(call: MethodCall, result: MethodChannel.Result) {
        val modelPath = call.argument<String>("modelPath")
        if (modelPath.isNullOrEmpty()) {
            result.error("bad_args", "modelPath is required.", null)
            return
        }

        if (engine != null && currentModelPath == modelPath) {
            result.success(null)
            return
        }

        val engineCfg = call.argument<Map<String, Any>>("engineConfig") ?: emptyMap()
        val convCfg = call.argument<Map<String, Any>>("conversationConfig") ?: emptyMap()

        scope.launch {
            try {
                conversation?.close()
                engine?.close()

                // Engine config
                val backend = parseBackend(engineCfg["backend"] as? String)
                val visionBackendStr = engineCfg["visionBackend"] as? String
                val audioBackendStr = engineCfg["audioBackend"] as? String
                val maxNumTokens = (engineCfg["maxNumTokens"] as? Number)?.toInt() ?: 4096
                benchmarkEnabled = engineCfg["enableBenchmark"] as? Boolean ?: false

                val config = EngineConfig(
                    modelPath = modelPath,
                    backend = backend,
                    visionBackend = if (visionBackendStr != null) parseBackend(visionBackendStr) else null,
                    audioBackend = if (audioBackendStr != null) parseBackend(audioBackendStr) else null,
                    maxNumTokens = maxNumTokens,
                    cacheDir = context.cacheDir.path,
                )
                val newEngine = Engine(config)
                newEngine.initialize()

                // Conversation config
                val systemPrompt = convCfg["systemPrompt"] as? String
                val samplerMap = convCfg["sampler"] as? Map<String, Any>
                val maxOutputTokens = (convCfg["maxOutputTokens"] as? Number)?.toInt()
                val initialMessages = convCfg["initialMessages"] as? List<Map<String, String>>

                val samplerConfig = if (samplerMap != null) {
                    SamplerConfig(
                        topK = (samplerMap["topK"] as? Number)?.toInt() ?: 40,
                        topP = (samplerMap["topP"] as? Number)?.toFloat() ?: 0.95f,
                        temperature = (samplerMap["temperature"] as? Number)?.toFloat() ?: 0.8f,
                    )
                } else null

                val messages = initialMessages?.map { msg ->
                    when (msg["role"]) {
                        "user" -> Message.user(msg["content"] ?: "")
                        "model" -> Message.model(msg["content"] ?: "")
                        else -> Message.user(msg["content"] ?: "")
                    }
                } ?: emptyList()

                val convConfig = ConversationConfig(
                    systemInstruction = if (systemPrompt != null) Contents.of(systemPrompt) else null,
                    samplerConfig = samplerConfig,
                    initialMessages = messages,
                )

                engine = newEngine
                conversation = newEngine.createConversation(convConfig)
                currentModelPath = modelPath

                launch(Dispatchers.Main) { result.success(null) }
            } catch (e: Exception) {
                launch(Dispatchers.Main) {
                    result.error("prepare_failed", e.localizedMessage, null)
                }
            }
        }
    }

    private fun handleGenerateStream(call: MethodCall, result: MethodChannel.Result) {
        val prompt = call.argument<String>("prompt")
        if (prompt.isNullOrEmpty()) {
            result.error("bad_args", "prompt is required.", null)
            return
        }

        val conv = conversation
        if (conv == null) {
            result.error("not_prepared", "Model is not prepared.", null)
            return
        }

        val sink = eventSink
        if (sink == null) {
            result.error("no_listener", "Stream listener not attached.", null)
            return
        }

        val imagePath = call.argument<String>("imagePath")

        val contents = if (imagePath != null) {
            Contents.of(Content.Text(prompt), Content.Image(imagePath))
        } else {
            Contents.of(prompt)
        }

        conv.sendMessageAsync(
            contents,
            object : MessageCallback {
                override fun onMessage(message: Message) {
                    val text = message.toString()
                    if (text.isNotEmpty()) {
                        scope.launch(Dispatchers.Main) { sink.success(text) }
                    }
                }

                override fun onDone() {
                    scope.launch(Dispatchers.Main) { sink.endOfStream() }
                }

                override fun onError(throwable: Throwable) {
                    if (throwable is java.util.concurrent.CancellationException) {
                        scope.launch(Dispatchers.Main) { sink.endOfStream() }
                    } else {
                        scope.launch(Dispatchers.Main) {
                            sink.error("stream_error", throwable.localizedMessage, null)
                        }
                    }
                }
            }
        )

        result.success(null)
    }

    private fun handleCancel(result: MethodChannel.Result) {
        conversation?.cancelProcess()
        result.success(null)
    }

    private fun handleReset(result: MethodChannel.Result) {
        val eng = engine ?: run {
            result.success(null)
            return
        }

        scope.launch {
            try {
                conversation?.close()
                conversation = eng.createConversation(ConversationConfig())
                launch(Dispatchers.Main) { result.success(null) }
            } catch (e: Exception) {
                launch(Dispatchers.Main) {
                    result.error("reset_failed", e.localizedMessage, null)
                }
            }
        }
    }

    private fun handleGetBenchmark(result: MethodChannel.Result) {
        // TODO: Expose benchmark info from Kotlin SDK when API is available
        result.success(null)
    }

    // -- EventChannel --

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
