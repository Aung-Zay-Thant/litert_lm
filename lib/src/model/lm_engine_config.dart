import 'lm_activation_type.dart';
import 'lm_backend.dart';

final class LmEngineConfig {
  const LmEngineConfig({
    this.backend = LmBackend.cpu,
    this.visionBackend,
    this.audioBackend,
    this.maxNumTokens = 4096,
    this.activationType,
    this.prefillChunkSize,
    this.enableBenchmark = false,
  }) : assert(maxNumTokens > 0),
       assert(prefillChunkSize == null || prefillChunkSize > 0);

  final LmBackend backend;
  final LmBackend? visionBackend;
  final LmBackend? audioBackend;
  final int maxNumTokens;
  final LmActivationType? activationType;
  final int? prefillChunkSize;
  final bool enableBenchmark;
}
