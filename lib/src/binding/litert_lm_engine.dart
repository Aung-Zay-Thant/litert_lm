import 'method_channel_litert_lm_platform.dart';

import '../model/lm_benchmark_info.dart';
import '../model/lm_capabilities.dart';
import '../model/lm_content_part.dart';
import '../model/lm_conversation_config.dart';
import '../model/lm_engine_config.dart';
import '../model/lm_session_config.dart';
import 'litert_lm_conversation.dart';
import 'litert_lm_platform.dart';

final class LiteRtLmEngine {
  LiteRtLmEngine({
    String methodChannelName = 'litert_lm/method',
    String eventChannelName = 'litert_lm/stream',
  }) : _platform = MethodChannelLitertLmPlatform(
         methodChannelName: methodChannelName,
         eventChannelName: eventChannelName,
       );

  LiteRtLmEngine._(this._platform);

  final LitertLmPlatform _platform;
  String? _engineId;
  LiteRtLmConversation? _legacyConversation;
  bool _isDisposed = false;

  static Future<LiteRtLmEngine> create({
    required String modelPath,
    LmEngineConfig config = const LmEngineConfig(),
    String methodChannelName = 'litert_lm/method',
    String eventChannelName = 'litert_lm/stream',
  }) async {
    final engine = LiteRtLmEngine._(
      MethodChannelLitertLmPlatform(
        methodChannelName: methodChannelName,
        eventChannelName: eventChannelName,
      ),
    );
    engine._engineId = await engine._platform.createEngine(
      modelPath: modelPath,
      config: config,
    );
    return engine;
  }

  bool get isPrepared => _engineId != null && !_isDisposed;

  bool get isDisposed => _isDisposed;

  Future<LmCapabilities> getCapabilities() {
    final engineId = _requireEngineId();
    return _platform.getCapabilities(engineId: engineId);
  }

  Future<LiteRtLmConversation> createConversation({
    LmConversationConfig conversationConfig = const LmConversationConfig(),
    LmSessionConfig sessionConfig = const LmSessionConfig(),
  }) async {
    final engineId = _requireEngineId();
    final conversationId = await _platform.createConversation(
      engineId: engineId,
      conversationConfig: conversationConfig,
      sessionConfig: sessionConfig,
    );
    return LiteRtLmConversation.internal(
      platform: _platform,
      engineId: engineId,
      conversationId: conversationId,
    );
  }

  @Deprecated('Use LiteRtLmEngine.create() and createConversation() instead.')
  Future<void> prepare({
    required String modelPath,
    String? systemPrompt,
    LmEngineConfig engineConfig = const LmEngineConfig(),
    LmConversationConfig? conversationConfig,
  }) async {
    _throwIfDisposed();
    if (_engineId != null) {
      await _disposePreparedState();
    }
    _engineId = await _platform.createEngine(
      modelPath: modelPath,
      config: engineConfig,
    );
    _legacyConversation = await createConversation(
      conversationConfig:
          conversationConfig ??
          LmConversationConfig(systemPrompt: systemPrompt),
    );
  }

  @Deprecated('Use LiteRtLmConversation.generateText() instead.')
  Stream<String> generateStream({required String prompt, String? imagePath}) {
    final conversation = _requireLegacyConversation();
    return conversation.generate(
      prompt: [
        LmTextPart(prompt),
        if (imagePath != null) LmImagePathPart(imagePath),
      ],
    );
  }

  @Deprecated('Use LiteRtLmConversation.cancelGeneration() instead.')
  Future<void> cancel() {
    return _requireLegacyConversation().cancelGeneration();
  }

  @Deprecated('Use LiteRtLmConversation.reset() instead.')
  Future<void> resetConversation() {
    return _requireLegacyConversation().reset();
  }

  @Deprecated('Use LiteRtLmConversation.getBenchmarkInfo() instead.')
  Future<LmBenchmarkInfo?> getBenchmarkInfo() {
    return _requireLegacyConversation().getBenchmarkInfo();
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    await _disposePreparedState();
    if (_platform
        case final MethodChannelLitertLmPlatform methodChannelPlatform) {
      methodChannelPlatform.dispose();
    }
    _isDisposed = true;
  }

  Future<void> _disposePreparedState() async {
    if (_legacyConversation != null && !_legacyConversation!.isDisposed) {
      await _legacyConversation!.dispose();
    }
    final engineId = _engineId;
    if (engineId != null) {
      await _platform.disposeEngine(engineId: engineId);
    }
    _engineId = null;
    _legacyConversation = null;
  }

  String _requireEngineId() {
    _throwIfDisposed();
    final engineId = _engineId;
    if (engineId == null) {
      throw StateError('Engine has not been created yet.');
    }
    return engineId;
  }

  LiteRtLmConversation _requireLegacyConversation() {
    final conversation = _legacyConversation;
    if (conversation == null || conversation.isDisposed) {
      throw StateError(
        'Legacy conversation is not available. Call prepare() first.',
      );
    }
    return conversation;
  }

  void _throwIfDisposed() {
    if (_isDisposed) {
      throw StateError('Engine has been disposed.');
    }
  }
}
