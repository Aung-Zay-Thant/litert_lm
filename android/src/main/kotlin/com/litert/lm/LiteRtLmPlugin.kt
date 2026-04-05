package com.litert.lm

import android.content.Context
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
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
import java.util.UUID
import java.util.concurrent.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class LiteRtLmPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private data class EngineRecord(
        val engine: Engine,
        val benchmarkEnabled: Boolean,
        val conversations: MutableMap<String, ConversationRecord> = mutableMapOf(),
    )

    private data class ConversationRecord(
        var conversation: Conversation,
        val conversationConfig: Map<String, Any?>,
        val sessionConfig: Map<String, Any?>,
        var activeRequestId: String? = null,
    )

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val engines = mutableMapOf<String, EngineRecord>()
    private var eventSink: EventChannel.EventSink? = null

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
        for (engineRecord in engines.values) {
            for (conversationRecord in engineRecord.conversations.values) {
                conversationRecord.conversation.close()
            }
            engineRecord.engine.close()
        }
        engines.clear()
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "engineCreate" -> handleEngineCreate(call, result)
            "engineDispose" -> handleEngineDispose(call, result)
            "engineGetCapabilities" -> handleEngineGetCapabilities(call, result)
            "conversationCreate" -> handleConversationCreate(call, result)
            "conversationDispose" -> handleConversationDispose(call, result)
            "conversationGenerate" -> handleConversationGenerate(call, result)
            "conversationCancel" -> handleConversationCancel(call, result)
            "conversationReset" -> handleConversationReset(call, result)
            "conversationGetBenchmarkInfo" -> handleConversationGetBenchmarkInfo(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleEngineCreate(call: MethodCall, result: MethodChannel.Result) {
        val modelPath = call.argument<String>("modelPath")
        if (modelPath.isNullOrEmpty()) {
            result.error("invalid_argument", "modelPath is required.", null)
            return
        }

        val engineConfig = call.argument<Map<String, Any?>>("engineConfig") ?: emptyMap()
        if (engineConfig["activationType"] != null || engineConfig["prefillChunkSize"] != null) {
            result.error("unsupported_feature", "Android SDK does not expose activation type or prefill chunk size in this binding.", null)
            return
        }
        if (engineConfig["enableBenchmark"] == true) {
            result.error("unsupported_feature", "Benchmark info is not available on Android in this binding.", null)
            return
        }

        scope.launch {
            try {
                val config = EngineConfig(
                    modelPath = modelPath,
                    backend = parseBackend(engineConfig["backend"] as? String),
                    visionBackend = (engineConfig["visionBackend"] as? String)?.let(::parseBackend),
                    audioBackend = (engineConfig["audioBackend"] as? String)?.let(::parseBackend),
                    maxNumTokens = (engineConfig["maxNumTokens"] as? Number)?.toInt() ?: 4096,
                    cacheDir = context.cacheDir.path,
                )
                val engine = Engine(config)
                engine.initialize()
                val engineId = UUID.randomUUID().toString()
                engines[engineId] = EngineRecord(engine = engine, benchmarkEnabled = false)
                launch(Dispatchers.Main) { result.success(engineId) }
            } catch (error: Exception) {
                launch(Dispatchers.Main) {
                    result.error("native_failure", error.localizedMessage, null)
                }
            }
        }
    }

    private fun handleEngineDispose(call: MethodCall, result: MethodChannel.Result) {
        val engineId = call.argument<String>("engineId")
        val engineRecord = engineId?.let { engines.remove(it) }
        if (engineRecord == null) {
            result.success(null)
            return
        }
        scope.launch {
            for (conversationRecord in engineRecord.conversations.values) {
                conversationRecord.conversation.close()
            }
            engineRecord.engine.close()
            launch(Dispatchers.Main) { result.success(null) }
        }
    }

    private fun handleEngineGetCapabilities(call: MethodCall, result: MethodChannel.Result) {
        val engineId = call.argument<String>("engineId")
        if (engineId == null || !engines.containsKey(engineId)) {
            result.error("not_found", "Engine not found.", null)
            return
        }
        result.success(
            mapOf(
                "supportsGpuBackend" to true,
                "supportsVisionInput" to true,
                "supportsAudioInput" to false,
                "supportsSeededSampling" to false,
                "supportsBenchmarkInfo" to false,
            )
        )
    }

    private fun handleConversationCreate(call: MethodCall, result: MethodChannel.Result) {
        val engineId = call.argument<String>("engineId")
        val engineRecord = engineId?.let { engines[it] }
        if (engineRecord == null) {
            result.error("not_found", "Engine not found.", null)
            return
        }

        val conversationConfig = call.argument<Map<String, Any?>>("conversationConfig") ?: emptyMap()
        val sessionConfig = call.argument<Map<String, Any?>>("sessionConfig") ?: emptyMap()
        val sampler = sessionConfig["sampler"] as? Map<String, Any?>
        if (sessionConfig["maxOutputTokens"] != null) {
            result.error("unsupported_feature", "Android SDK does not expose maxOutputTokens in this binding.", null)
            return
        }
        if (sampler?.get("seed") != null) {
            result.error("unsupported_feature", "Android SDK does not expose seeded sampling in this binding.", null)
            return
        }

        scope.launch {
            try {
                val conversation = createConversation(engineRecord.engine, conversationConfig, sessionConfig)
                val conversationId = UUID.randomUUID().toString()
                engineRecord.conversations[conversationId] = ConversationRecord(
                    conversation = conversation,
                    conversationConfig = HashMap(conversationConfig),
                    sessionConfig = HashMap(sessionConfig),
                )
                launch(Dispatchers.Main) { result.success(conversationId) }
            } catch (error: Exception) {
                launch(Dispatchers.Main) {
                    result.error("native_failure", error.localizedMessage, null)
                }
            }
        }
    }

    private fun handleConversationDispose(call: MethodCall, result: MethodChannel.Result) {
        val record = findConversation(call, result) ?: return
        val removed = record.first.conversations.remove(record.second)
        removed?.conversation?.close()
        result.success(null)
    }

    private fun handleConversationGenerate(call: MethodCall, result: MethodChannel.Result) {
        val located = findConversation(call, result) ?: return
        val conversationRecord = located.third
        val requestId = call.argument<String>("requestId")
        if (requestId.isNullOrEmpty()) {
            result.error("invalid_argument", "requestId is required.", null)
            return
        }
        if (eventSink == null) {
            result.error("native_failure", "Stream listener not attached.", null)
            return
        }
        if (conversationRecord.activeRequestId != null) {
            result.error("native_failure", "Conversation is already generating.", null)
            return
        }

        val prompt = call.argument<List<Map<String, Any?>>>("prompt")
        if (prompt.isNullOrEmpty()) {
            result.error("invalid_argument", "prompt is required.", null)
            return
        }

        val contents = try {
            buildPromptContents(prompt)
        } catch (error: IllegalArgumentException) {
            result.error("invalid_argument", error.message, null)
            return
        }

        conversationRecord.activeRequestId = requestId
        conversationRecord.conversation.sendMessageAsync(
            contents,
            object : MessageCallback {
                override fun onMessage(message: Message) {
                    emitEvent(mapOf("requestId" to requestId, "type" to "chunk", "text" to message.toString()))
                }

                override fun onDone() {
                    conversationRecord.activeRequestId = null
                    emitEvent(mapOf("requestId" to requestId, "type" to "done"))
                }

                override fun onError(throwable: Throwable) {
                    conversationRecord.activeRequestId = null
                    val code = if (throwable is CancellationException) {
                        "generation_cancelled"
                    } else {
                        "native_failure"
                    }
                    emitEvent(
                        mapOf(
                            "requestId" to requestId,
                            "type" to "error",
                            "code" to code,
                            "message" to (throwable.localizedMessage ?: "Generation failed."),
                        )
                    )
                }
            }
        )

        result.success(null)
    }

    private fun handleConversationCancel(call: MethodCall, result: MethodChannel.Result) {
        val record = findConversation(call, result) ?: return
        record.third.conversation.cancelProcess()
        result.success(null)
    }

    private fun handleConversationReset(call: MethodCall, result: MethodChannel.Result) {
        val located = findConversation(call, result) ?: return
        scope.launch {
            try {
                located.third.conversation.close()
                located.third.conversation = createConversation(
                    located.first.engine,
                    located.third.conversationConfig,
                    located.third.sessionConfig,
                )
                located.third.activeRequestId = null
                launch(Dispatchers.Main) { result.success(null) }
            } catch (error: Exception) {
                launch(Dispatchers.Main) {
                    result.error("native_failure", error.localizedMessage, null)
                }
            }
        }
    }

    private fun handleConversationGetBenchmarkInfo(call: MethodCall, result: MethodChannel.Result) {
        val record = findConversation(call, result) ?: return
        if (record.first.benchmarkEnabled) {
            result.error("unsupported_feature", "Benchmark info is not available on Android in this binding.", null)
            return
        }
        result.success(null)
    }

    private fun createConversation(
        engine: Engine,
        conversationConfigMap: Map<String, Any?>,
        sessionConfigMap: Map<String, Any?>,
    ): Conversation {
        val systemPrompt = conversationConfigMap["systemPrompt"] as? String
        val initialMessages = (conversationConfigMap["initialMessages"] as? List<Map<String, Any?>>).orEmpty()
        val samplerMap = sessionConfigMap["sampler"] as? Map<String, Any?>

        val samplerConfig = samplerMap?.let {
            SamplerConfig(
                topK = (it["topK"] as? Number)?.toInt() ?: 40,
                topP = (it["topP"] as? Number)?.toFloat() ?: 0.95f,
                temperature = (it["temperature"] as? Number)?.toFloat() ?: 0.8f,
            )
        }

        val initialHistory = initialMessages.map { message ->
            val role = message["role"] as? String ?: "user"
            val text = extractTextParts((message["content"] as? List<Map<String, Any?>>).orEmpty())
            when (role) {
                "model" -> Message.model(text)
                "system" -> Message.user(text)
                else -> Message.user(text)
            }
        }

        // Tools
        val toolsList = (conversationConfigMap["tools"] as? List<Map<String, Any?>>).orEmpty()
        val tools = toolsList.mapNotNull { toolDef ->
            val function = toolDef["function"] as? Map<String, Any?> ?: return@mapNotNull null
            val name = function["name"] as? String ?: return@mapNotNull null
            val description = function["description"] as? String ?: ""
            val params = function["parameters"] as? Map<String, Any?> ?: emptyMap()
            // Use OpenApiTool for each tool definition
            object : com.google.ai.edge.litertlm.OpenApiTool {
                override fun getToolDescriptionJsonString(): String {
                    val json = org.json.JSONObject()
                    json.put("name", name)
                    json.put("description", description)
                    json.put("parameters", org.json.JSONObject(params))
                    return json.toString()
                }
                override fun execute(paramsJsonString: String): String {
                    // Tool execution happens on Dart side, not here
                    return "{\"error\": \"Tool execution should happen on Dart side\"}"
                }
            }
        }

        val constrainedDecoding = conversationConfigMap["constrainedDecoding"] as? Boolean ?: false

        val config = ConversationConfig(
            systemInstruction = systemPrompt?.let { Contents.of(it) },
            samplerConfig = samplerConfig,
            initialMessages = initialHistory,
            tools = tools.map { com.google.ai.edge.litertlm.tool(it) },
            automaticToolCalling = false,
        )

        if (constrainedDecoding) {
            com.google.ai.edge.litertlm.ExperimentalFlags.enableConversationConstrainedDecoding = true
        }
        val conversation = engine.createConversation(config)
        if (constrainedDecoding) {
            com.google.ai.edge.litertlm.ExperimentalFlags.enableConversationConstrainedDecoding = false
        }

        return conversation
    }

    private fun buildPromptContents(prompt: List<Map<String, Any?>>): Contents {
        val parts = prompt.map { part ->
            when (part["type"] as? String) {
                "text" -> {
                    val text = part["text"] as? String
                        ?: throw IllegalArgumentException("Text prompt part is missing text.")
                    Content.Text(text)
                }

                "image_path" -> {
                    val path = part["path"] as? String
                        ?: throw IllegalArgumentException("Image prompt part is missing path.")
                    Content.Image(path)
                }

                else -> throw IllegalArgumentException("Unsupported prompt part.")
            }
        }
        return Contents.of(*parts.toTypedArray())
    }

    private fun extractTextParts(parts: List<Map<String, Any?>>): String {
        return parts.mapNotNull { part ->
            if (part["type"] == "text") part["text"] as? String else null
        }.joinToString(separator = "")
    }

    private fun findConversation(
        call: MethodCall,
        result: MethodChannel.Result,
    ): Triple<EngineRecord, String, ConversationRecord>? {
        val engineId = call.argument<String>("engineId")
        val conversationId = call.argument<String>("conversationId")
        if (engineId.isNullOrEmpty() || conversationId.isNullOrEmpty()) {
            result.error("invalid_argument", "engineId and conversationId are required.", null)
            return null
        }
        val engineRecord = engines[engineId]
        if (engineRecord == null) {
            result.error("not_found", "Engine not found.", null)
            return null
        }
        val conversationRecord = engineRecord.conversations[conversationId]
        if (conversationRecord == null) {
            result.error("not_found", "Conversation not found.", null)
            return null
        }
        return Triple(engineRecord, conversationId, conversationRecord)
    }

    private fun parseBackend(name: String?): Backend {
        return when (name) {
            "gpu" -> Backend.GPU()
            else -> Backend.CPU()
        }
    }

    private fun emitEvent(event: Map<String, Any?>) {
        val sink = eventSink ?: return
        scope.launch(Dispatchers.Main) {
            sink.success(event)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
