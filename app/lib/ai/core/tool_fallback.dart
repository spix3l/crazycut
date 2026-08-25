/// Tool calling for backends that do not have it (AI-9).
///
/// Companion to `schema_fallback.dart`. Where an adapter reports
/// `capabilities.tools == false` — most small local models, some
/// OpenAI-compatible shims — this describes the available tools in the prompt
/// and parses calls back out of the reply text, so `AgentRunner` runs one loop
/// regardless of what is underneath it.
library;

import 'dart:convert';

import 'package:crazycut_app/ai/core/llm_message.dart';
import 'package:crazycut_app/ai/core/schema_fallback.dart';

/// Sentinel the model is asked to emit. Chosen to be something no model
/// produces by accident in prose.
const _callMarker = 'TOOL_CALL:';

/// Rewrites [request] so a tool-less backend can still be asked to call tools.
LlmRequest describeToolsInPrompt(LlmRequest request) {
  if (request.tools.isEmpty) return request;

  final catalogue = request.tools
      .map(
        (t) =>
            '- ${t.name}: ${t.description}\n'
            '  arguments schema: ${jsonEncode(t.schema)}',
      )
      .join('\n');

  final instruction = LlmMessage.system(
    'You can run tools. To run one, reply with a line starting exactly with '
    '$_callMarker followed by a JSON object of the form '
    '{"name": "<tool>", "arguments": {...}}, and nothing else on that line. '
    'Emit one such line per tool you want to run; you may emit several. '
    'Do not describe the call in prose instead of emitting it — a call that is '
    'only described never runs. When you have the answer and need no more '
    'tools, reply normally with no $_callMarker line.\n\n'
    'Available tools:\n$catalogue',
  );

  final systems = request.messages.where((m) => m.role == LlmRole.system);
  final rest = request.messages.where((m) => m.role != LlmRole.system);
  return request.copyWith(
    messages: [...systems, instruction, ...rest],
    tools: const [],
  );
}

/// Parses text-protocol tool calls out of [response], returning a response in
/// the same shape a natively tool-calling provider would have produced.
///
/// Returns [response] unchanged when there are no calls in it.
LlmResponse parseToolCallsFromText(LlmResponse response) {
  final text = response.text;
  if (!text.contains(_callMarker)) return response;

  final parts = <LlmPart>[];
  final prose = StringBuffer();
  var index = 0;

  for (final line in const LineSplitter().convert(text)) {
    final marker = line.indexOf(_callMarker);
    if (marker < 0) {
      prose.writeln(line);
      continue;
    }
    // Anything before the marker on this line is still prose.
    final before = line.substring(0, marker).trim();
    if (before.isNotEmpty) prose.writeln(before);

    final payload = extractJson(line.substring(marker + _callMarker.length));
    if (payload is! Map) {
      // Malformed call: keep it as prose rather than inventing arguments. The
      // model gets a chance to correct itself on the next turn.
      prose.writeln(line);
      continue;
    }
    final name = payload['name'];
    if (name is! String || name.isEmpty) {
      prose.writeln(line);
      continue;
    }
    final args = payload['arguments'];
    parts.add(
      ToolCallPart(
        id: 'text-call-${index++}',
        name: name,
        args: args is Map ? Map<String, dynamic>.from(args) : const {},
      ),
    );
  }

  if (parts.isEmpty) return response;

  final leading = prose.toString().trim();
  return LlmResponse(
    parts: [if (leading.isNotEmpty) TextPart(leading), ...parts],
    finishReason: LlmFinishReason.toolCalls,
    usage: response.usage,
    model: response.model,
  );
}

/// Renders tool results as a user turn a tool-less backend can read. Native
/// providers get structured [ToolResultPart]s instead; this is the text form of
/// the same thing.
LlmMessage renderToolResultsAsText(List<ToolResultPart> results) {
  final body = results
      .map(
        (r) =>
            '${r.isError ? 'TOOL_ERROR' : 'TOOL_RESULT'} '
            '(${r.callId}): ${r.content}',
      )
      .join('\n\n');
  return LlmMessage.user(body);
}
