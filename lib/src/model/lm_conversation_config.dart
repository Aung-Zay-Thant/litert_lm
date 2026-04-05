import 'lm_message.dart';
import 'lm_tool_definition.dart';

final class LmConversationConfig {
  const LmConversationConfig({
    this.systemPrompt,
    this.initialMessages = const [],
    this.tools = const [],
    this.constrainedDecoding = false,
  });

  /// System prompt to set the AI persona.
  final String? systemPrompt;

  /// Pre-seed conversation with message history.
  final List<LmMessage> initialMessages;

  /// Tool definitions the model can call.
  /// When non-empty, the model can output structured tool calls.
  final List<LmToolDefinition> tools;

  /// Enable constrained decoding for tool calls.
  /// Forces the model to output valid JSON when calling tools.
  /// Critical for reliable on-device tool calling with smaller models.
  final bool constrainedDecoding;
}
