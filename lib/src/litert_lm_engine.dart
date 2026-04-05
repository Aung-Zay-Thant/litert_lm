import 'dart:async';

import 'package:flutter/services.dart';

/// Backend for inference computation.
enum LmBackend { cpu, gpu }

/// Activation data type for the engine.
enum LmActivationType { f32, f16, i16, i8 }

/// Sampler configuration for controlling response randomness.
class LmSamplerConfig {
  const LmSamplerConfig({
    this.topK = 40,
    this.topP = 0.95,
    this.temperature = 0.8,
    this.seed,
  });

  /// Number of top tokens to consider. Lower = more focused.
  final int topK;

  /// Cumulative probability threshold. Lower = more focused.
  final double topP;

  /// Controls randomness. 0.0 = deterministic, 1.0+ = creative.
  final double temperature;

  /// Random seed for reproducible output. Null = random.
  final int? seed;

  Map<String, dynamic> toMap() => {
    'topK': topK,
    'topP': topP,
    'temperature': temperature,
    if (seed != null) 'seed': seed,
  };
}

/// Engine configuration for model loading.
class LmEngineConfig {
  const LmEngineConfig({
    this.backend = LmBackend.cpu,
    this.visionBackend,
    this.audioBackend,
    this.maxNumTokens = 4096,
    this.activationType,
    this.prefillChunkSize,
    this.enableBenchmark = false,
  });

  /// Primary compute backend.
  final LmBackend backend;

  /// Vision backend for multimodal models. Null = disabled.
  final LmBackend? visionBackend;

  /// Audio backend for audio-capable models. Null = disabled.
  final LmBackend? audioBackend;

  /// Maximum number of tokens the engine can handle.
  final int maxNumTokens;

  /// Activation data type. Null = engine default (usually F32).
  final LmActivationType? activationType;

  /// Prefill chunk size for CPU backend. Null = engine default.
  final int? prefillChunkSize;

  /// Enable benchmarking to measure tokens/sec.
  final bool enableBenchmark;

  Map<String, dynamic> toMap() => {
    'backend': backend.name,
    if (visionBackend != null) 'visionBackend': visionBackend!.name,
    if (audioBackend != null) 'audioBackend': audioBackend!.name,
    'maxNumTokens': maxNumTokens,
    if (activationType != null) 'activationType': activationType!.index,
    if (prefillChunkSize != null) 'prefillChunkSize': prefillChunkSize,
    'enableBenchmark': enableBenchmark,
  };
}

/// Conversation configuration.
class LmConversationConfig {
  const LmConversationConfig({
    this.systemPrompt,
    this.sampler,
    this.maxOutputTokens,
    this.initialMessages,
  });

  /// System prompt to set the AI persona.
  final String? systemPrompt;

  /// Sampler configuration (temperature, top-k, top-p).
  final LmSamplerConfig? sampler;

  /// Maximum output tokens per response. Null = engine default.
  final int? maxOutputTokens;

  /// Pre-seed conversation with message history.
  /// Each entry: `{'role': 'user'|'model', 'content': 'text'}`.
  final List<Map<String, String>>? initialMessages;

  Map<String, dynamic> toMap() => {
    if (systemPrompt != null) 'systemPrompt': systemPrompt,
    if (sampler != null) 'sampler': sampler!.toMap(),
    if (maxOutputTokens != null) 'maxOutputTokens': maxOutputTokens,
    if (initialMessages != null) 'initialMessages': initialMessages,
  };
}

/// Benchmark results from inference.
class LmBenchmarkInfo {
  const LmBenchmarkInfo({
    required this.timeToFirstToken,
    required this.initTime,
    required this.prefillTokensPerSec,
    required this.decodeTokensPerSec,
  });

  factory LmBenchmarkInfo.fromMap(Map<String, dynamic> map) {
    return LmBenchmarkInfo(
      timeToFirstToken: (map['timeToFirstToken'] as num?)?.toDouble() ?? 0,
      initTime: (map['initTime'] as num?)?.toDouble() ?? 0,
      prefillTokensPerSec:
          (map['prefillTokensPerSec'] as num?)?.toDouble() ?? 0,
      decodeTokensPerSec: (map['decodeTokensPerSec'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Time to first token in seconds.
  final double timeToFirstToken;

  /// Total initialization time in seconds.
  final double initTime;

  /// Prefill speed (tokens per second).
  final double prefillTokensPerSec;

  /// Decode speed (tokens per second).
  final double decodeTokensPerSec;

  @override
  String toString() =>
      'TTFT: ${timeToFirstToken.toStringAsFixed(2)}s, '
      'decode: ${decodeTokensPerSec.toStringAsFixed(1)} tok/s';
}

/// On-device LLM inference engine powered by LiteRT-LM.
class LiteRtLmEngine {
  LiteRtLmEngine({
    String methodChannelName = 'litert_lm/method',
    String eventChannelName = 'litert_lm/stream',
  }) : _channel = MethodChannel(methodChannelName),
       _streamChannel = EventChannel(eventChannelName);

  final MethodChannel _channel;
  final EventChannel _streamChannel;

  bool _isPrepared = false;

  /// Whether the engine has been prepared with a model.
  bool get isPrepared => _isPrepared;

  /// Prepares the engine with a model file.
  ///
  /// [modelPath] — absolute path to the `.litertlm` model file.
  /// [engineConfig] — engine settings (backend, tokens, activation type).
  /// [conversationConfig] — conversation settings (system prompt, sampler).
  ///
  /// For simple usage, pass [systemPrompt] directly instead of a full config.
  /// This is a no-op if the same model is already loaded.
  Future<void> prepare({
    required String modelPath,
    String? systemPrompt,
    LmEngineConfig engineConfig = const LmEngineConfig(),
    LmConversationConfig? conversationConfig,
  }) async {
    final args = <String, dynamic>{
      'modelPath': modelPath,
      'engineConfig': engineConfig.toMap(),
    };

    // Allow simple systemPrompt or full conversationConfig
    if (conversationConfig != null) {
      args['conversationConfig'] = conversationConfig.toMap();
    } else if (systemPrompt != null) {
      args['conversationConfig'] = LmConversationConfig(
        systemPrompt: systemPrompt,
      ).toMap();
    }

    await _channel.invokeMethod<void>('prepareModel', args);
    _isPrepared = true;
  }

  /// Generates a streaming response from a text prompt.
  ///
  /// Returns a [Stream] of text chunks. Listen until the stream closes.
  /// Optionally attach an [imagePath] for multimodal (vision) prompts.
  Stream<String> generateStream({required String prompt, String? imagePath}) {
    final controller = StreamController<String>();

    final subscription = _streamChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is String) controller.add(event);
      },
      onError: (Object error) {
        controller.addError(error);
        controller.close();
      },
      onDone: () => controller.close(),
    );

    controller.onCancel = () => subscription.cancel();

    scheduleMicrotask(() async {
      try {
        final args = <String, dynamic>{'prompt': prompt};
        if (imagePath != null) args['imagePath'] = imagePath;
        await _channel.invokeMethod<void>('generateTextStream', args);
      } catch (error) {
        controller.addError(error);
        controller.close();
      }
    });

    return controller.stream;
  }

  /// Cancels the current generation.
  Future<void> cancel() => _channel.invokeMethod<void>('cancelGeneration');

  /// Resets the conversation context. Next prompt starts fresh.
  Future<void> resetConversation() =>
      _channel.invokeMethod<void>('resetConversation');

  /// Gets benchmark info from the last inference.
  /// Returns null if benchmarking is not enabled.
  Future<LmBenchmarkInfo?> getBenchmarkInfo() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'getBenchmarkInfo',
    );
    if (result == null) return null;
    final map = result.cast<String, dynamic>();
    return LmBenchmarkInfo.fromMap(map);
  }
}
