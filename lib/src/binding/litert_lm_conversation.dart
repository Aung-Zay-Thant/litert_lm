import '../model/lm_benchmark_info.dart';
import '../model/lm_content_part.dart';
import 'litert_lm_platform.dart';

final class LiteRtLmConversation {
  LiteRtLmConversation.internal({
    required LitertLmPlatform platform,
    required String engineId,
    required String conversationId,
  }) : _platform = platform,
       _engineId = engineId,
       _conversationId = conversationId;

  final LitertLmPlatform _platform;
  final String _engineId;
  final String _conversationId;
  bool _isDisposed = false;

  bool get isDisposed => _isDisposed;

  Stream<String> generate({required List<LmContentPart> prompt}) {
    _throwIfDisposed();
    return _platform.generate(
      engineId: _engineId,
      conversationId: _conversationId,
      prompt: prompt,
    );
  }

  Stream<String> generateText(String text) {
    return generate(prompt: [LmTextPart(text)]);
  }

  /// Send a tool response back to the conversation and stream the model's
  /// follow-up response. This is the proper way to feed tool results back
  /// after the model outputs a tool call.
  Stream<String> sendToolResponse({
    required String toolName,
    required String toolResult,
  }) {
    _throwIfDisposed();
    return _platform.sendToolResponse(
      engineId: _engineId,
      conversationId: _conversationId,
      toolName: toolName,
      toolResult: toolResult,
    );
  }

  Future<void> cancelGeneration() {
    _throwIfDisposed();
    return _platform.cancelGeneration(
      engineId: _engineId,
      conversationId: _conversationId,
    );
  }

  Future<void> reset() {
    _throwIfDisposed();
    return _platform.resetConversation(
      engineId: _engineId,
      conversationId: _conversationId,
    );
  }

  Future<LmBenchmarkInfo?> getBenchmarkInfo() {
    _throwIfDisposed();
    return _platform.getBenchmarkInfo(
      engineId: _engineId,
      conversationId: _conversationId,
    );
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    await _platform.disposeConversation(
      engineId: _engineId,
      conversationId: _conversationId,
    );
    _isDisposed = true;
  }

  void _throwIfDisposed() {
    if (_isDisposed) {
      throw StateError('Conversation has been disposed.');
    }
  }
}
