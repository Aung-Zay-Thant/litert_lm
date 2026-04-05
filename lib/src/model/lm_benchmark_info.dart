final class LmBenchmarkInfo {
  const LmBenchmarkInfo({
    required this.timeToFirstToken,
    required this.initTime,
    required this.prefillTokensPerSecond,
    required this.decodeTokensPerSecond,
  });

  final double timeToFirstToken;
  final double initTime;
  final double prefillTokensPerSecond;
  final double decodeTokensPerSecond;
}
