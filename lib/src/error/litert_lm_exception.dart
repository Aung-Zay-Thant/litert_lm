import 'litert_lm_error_code.dart';

final class LitertLmException implements Exception {
  const LitertLmException({
    required this.code,
    required this.message,
    this.details,
  });

  final LitertLmErrorCode code;
  final String message;
  final Object? details;

  @override
  String toString() => 'LitertLmException(code: $code, message: $message)';
}
