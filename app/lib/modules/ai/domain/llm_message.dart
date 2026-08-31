/// Normalized message model for the AI layer (AI-6).
///
/// Nothing in this file knows about any particular vendor. Providers translate
/// these types to and from their own wire formats; features and the agent loop
/// only ever see what is here.
library;

import 'package:collection/collection.dart';

part 'llm_delta.dart';
part 'llm_finish_reason.dart';
part 'llm_part.dart';
part 'llm_reasoning.dart';
part 'llm_request.dart';
part 'llm_response.dart';
part 'llm_role.dart';
part 'llm_tool_def.dart';
part 'llm_usage.dart';
part 'text_part.dart';
part 'tool_call_part.dart';
part 'tool_result_part.dart';

class LlmMessage {
  const LlmMessage(this.role, this.parts);

  LlmMessage.system(String text)
    : role = LlmRole.system,
      parts = [TextPart(text)];
  LlmMessage.user(String text) : role = LlmRole.user, parts = [TextPart(text)];
  LlmMessage.assistant(String text)
    : role = LlmRole.assistant,
      parts = [TextPart(text)];

  /// Tool results travel as a user turn. All results for one assistant turn
  /// belong in a single message — splitting them across turns teaches models to
  /// stop making parallel calls (AI-11).
  LlmMessage.toolResults(List<ToolResultPart> results)
    : role = LlmRole.user,
      parts = results;

  final LlmRole role;
  final List<LlmPart> parts;

  String get text =>
      parts.whereType<TextPart>().map((p) => p.text).join().trim();
}
