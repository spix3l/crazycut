part of 'llm_message.dart';

/// The model asking for a tool to run. [id] is the provider's correlation id
/// and must be echoed back on the matching [ToolResultPart].
class ToolCallPart extends LlmPart {
  const ToolCallPart({required this.id, required this.name, required this.args});
  final String id;
  final String name;
  final Map<String, dynamic> args;
}
