part of 'llm_message.dart';

/// A streamed increment. Only text streams incrementally; tool calls arrive
/// whole, because a half-parsed call is not useful to anyone.
class LlmDelta {
  const LlmDelta.text(this.text) : done = false, response = null;
  const LlmDelta.done(this.response) : text = '', done = true;

  final String text;
  final bool done;
  final LlmResponse? response;
}

/// Pairs each [ToolCallPart] with the tool definition it names, or null when
/// the model invented a tool that does not exist.
Iterable<(ToolCallPart, LlmToolDef?)> resolveToolCalls(
  List<ToolCallPart> calls,
  List<LlmToolDef> tools,
) sync* {
  for (final call in calls) {
    yield (call, tools.firstWhereOrNull((t) => t.name == call.name));
  }
}
