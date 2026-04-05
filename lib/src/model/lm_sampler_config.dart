final class LmSamplerConfig {
  const LmSamplerConfig({
    this.topK = 40,
    this.topP = 0.95,
    this.temperature = 0.8,
    this.seed,
  }) : assert(topK > 0),
       assert(topP > 0 && topP <= 1),
       assert(temperature >= 0);

  final int topK;
  final double topP;
  final double temperature;
  final int? seed;
}
