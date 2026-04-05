final class EventEnvelope {
  const EventEnvelope({
    required this.requestId,
    required this.type,
    this.text,
    this.code,
    this.message,
  });

  factory EventEnvelope.fromMap(Map<Object?, Object?> raw) {
    final requestId = raw['requestId'];
    final type = raw['type'];
    if (requestId is! String || type is! String) {
      throw const FormatException('Invalid event envelope.');
    }
    return EventEnvelope(
      requestId: requestId,
      type: type,
      text: raw['text'] as String?,
      code: raw['code'] as String?,
      message: raw['message'] as String?,
    );
  }

  final String requestId;
  final String type;
  final String? text;
  final String? code;
  final String? message;
}
