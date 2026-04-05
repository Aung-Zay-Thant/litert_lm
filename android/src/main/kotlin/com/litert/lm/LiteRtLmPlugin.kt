package com.litert.lm

import android.content.Context
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback
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

    // -- MethodChannel handler --

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareModel" -> handlePrepareModel(call, result)
            "generateTextStream" -> handleGenerateStream(call, result)
            "cancelGeneration" -> handleCancel(result)
            "resetConversation" -> handleReset(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handlePrepareModel(call: MethodCall, result: MethodChannel.Result) {
        val modelPath = call.argument<String>("modelPath")
        if (modelPath.isNullOrEmpty()) {
            result.error("bad_args", "modelPath is required.", null)
            return
        }

        // Skip if same model already loaded
        if (engine != null && currentModelPath == modelPath) {
            result.success(null)
            return
        }

        val systemPrompt = call.argument<String>("systemPrompt")

        scope.launch {
            try {
                // Clean up previous engine
                conversation?.close()
                engine?.close()

                val config = EngineConfig(
                    modelPath = modelPath,
                    backend = Backend.CPU(),
                    visionBackend = Backend.CPU(),
                    maxNumTokens = 4096,
                    cacheDir = context.cacheDir.path,
                )
                val newEngine = Engine(config)
                newEngine.initialize()

                val convConfig = if (systemPrompt != null) {
                    ConversationConfig(
                        systemInstruction = Contents.of(systemPrompt),
                    )
                } else {
                    ConversationConfig()
                }

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

        // Build message content
        val contents = if (imagePath != null) {
            Contents.of(
                com.google.ai.edge.litertlm.Content.Text(prompt),
                com.google.ai.edge.litertlm.Content.Image(imagePath),
            )
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
                        // User cancelled — just end the stream
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

    private fun handleReset(call: MethodCall, result: MethodChannel.Result) {
        val eng = engine
        if (eng == null) {
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

    // -- EventChannel handler --

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
