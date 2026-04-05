import '../model/lm_benchmark_info.dart';
import '../model/lm_capabilities.dart';
import '../model/lm_content_part.dart';
import '../model/lm_conversation_config.dart';
import '../model/lm_engine_config.dart';
import '../model/lm_session_config.dart';

abstract interface class LitertLmPlatform {
  Future<String> createEngine({
    required String modelPath,
    required LmEngineConfig config,
  });

  Future<void> disposeEngine({required String engineId});

  Future<LmCapabilities> getCapabilities({required String engineId});

  Future<String> createConversation({
    required String engineId,
    required LmConversationConfig conversationConfig,
    required LmSessionConfig sessionConfig,
  });

  Future<void> disposeConversation({
    required String engineId,
    required String conversationId,
  });

  Stream<String> generate({
    required String engineId,
    required String conversationId,
    required List<LmContentPart> prompt,
  });

  Future<void> cancelGeneration({
    required String engineId,
    required String conversationId,
  });

  Future<void> resetConversation({
    required String engineId,
    required String conversationId,
  });

  Future<LmBenchmarkInfo?> getBenchmarkInfo({
    required String engineId,
    required String conversationId,
  });
}
