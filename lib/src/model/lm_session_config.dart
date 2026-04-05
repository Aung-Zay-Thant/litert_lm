import 'lm_sampler_config.dart';

final class LmSessionConfig {
  const LmSessionConfig({this.maxOutputTokens, this.sampler})
    : assert(maxOutputTokens == null || maxOutputTokens > 0);

  final int? maxOutputTokens;
  final LmSamplerConfig? sampler;
}
