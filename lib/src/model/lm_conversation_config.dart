import 'lm_message.dart';

final class LmConversationConfig {
  const LmConversationConfig({
    this.systemPrompt,
    this.initialMessages = const [],
  });

  final String? systemPrompt;
  final List<LmMessage> initialMessages;
}
