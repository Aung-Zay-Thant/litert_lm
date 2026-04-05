/// Defines a tool that the LLM can call.
///
/// Uses the standard function-calling JSON format compatible with
/// Gemma 4's native tool calling tokens.
final class LmToolDefinition {
  const LmToolDefinition({
    required this.name,
    required this.description,
    this.parameters = const {},
  });

  /// Tool function name (e.g. "get_weather").
  final String name;

  /// Human-readable description of what the tool does.
  final String description;

  /// JSON Schema for the parameters object.
  /// Example: `{"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}`
  final Map<String, dynamic> parameters;

  Map<String, dynamic> toJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters.isEmpty
              ? {'type': 'object', 'properties': <String, dynamic>{}}
              : parameters,
        },
      };
}
