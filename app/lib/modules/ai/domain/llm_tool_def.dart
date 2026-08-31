part of 'llm_message.dart';

/// A tool the model may call. [schema] is JSON Schema for the arguments.
class LlmToolDef {
  const LlmToolDef({
    required this.name,
    required this.description,
    required this.schema,
  });
  final String name;
  final String description;
  final Map<String, dynamic> schema;
}
