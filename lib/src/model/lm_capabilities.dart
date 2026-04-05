final class LmCapabilities {
  const LmCapabilities({
    required this.supportsGpuBackend,
    required this.supportsVisionInput,
    required this.supportsAudioInput,
    required this.supportsSeededSampling,
    required this.supportsBenchmarkInfo,
  });

  final bool supportsGpuBackend;
  final bool supportsVisionInput;
  final bool supportsAudioInput;
  final bool supportsSeededSampling;
  final bool supportsBenchmarkInfo;
}
