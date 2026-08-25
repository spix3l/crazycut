/// Normalized message model for the AI layer (AI-6).
///
/// Nothing in this file knows about any particular vendor. Providers translate
/// these types to and from their own wire formats; features and the agent loop
/// only ever see what is here.
library;

import 'package:collection/collection.dart';

enum LlmRole { system, user, assistant }

/// One piece of a message. Messages are lists of parts because a single
/// assistant turn routinely mixes prose with tool calls.
sealed class LlmPart {
  const LlmPart();
}

class TextPart extends LlmPart {
  const TextPart(this.text);
  final String text;
}

/// The model asking for a tool to run. [id] is the provider's correlation id
/// and must be echoed back on the matching [ToolResultPart].
class ToolCallPart extends LlmPart {
  const ToolCallPart({required this.id, required this.name, required this.args});
  final String id;
  final String name;
  final Map<String, dynamic> args;
}

/// The answer to a [ToolCallPart]. A failed tool returns one of these with
/// [isError] set rather than being dropped, so the model can recover (AI-12).
class ToolResultPart extends LlmPart {
  const ToolResultPart({
    required this.callId,
    required this.content,
    this.isError = false,
  });
  final String callId;
  final String content;
  final bool isError;
}

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

/// How hard the model should think.
///
/// Deliberately an intent rather than a token count: providers express thinking
/// depth in mutually incompatible ways (token budgets, effort levels, a boolean,
/// or not at all). Each adapter maps the intent onto its own wire format and the
/// core stays out of it (AI-6).
enum LlmReasoning { none, auto, deep }

class LlmRequest {
  const LlmRequest({
    required this.messages,
    this.tools = const [],
    this.responseSchema,
    this.maxTokens = 8192,
    this.reasoning = LlmReasoning.auto,
    this.temperature,
  });

  final List<LlmMessage> messages;
  final List<LlmToolDef> tools;

  /// When set, the reply must be a single JSON value matching this schema.
  /// Providers without server-side enforcement are handled by the core's
  /// fallback rather than by callers (AI-9).
  final Map<String, dynamic>? responseSchema;

  final int maxTokens;
  final LlmReasoning reasoning;

  /// Only sent by adapters whose provider still accepts it. Several current
  /// models reject sampling parameters outright, so this stays unset by default.
  final double? temperature;

  LlmRequest copyWith({
    List<LlmMessage>? messages,
    List<LlmToolDef>? tools,
    Map<String, dynamic>? responseSchema,
    bool clearResponseSchema = false,
    int? maxTokens,
    LlmReasoning? reasoning,
  }) {
    return LlmRequest(
      messages: messages ?? this.messages,
      tools: tools ?? this.tools,
      responseSchema: clearResponseSchema
          ? null
          : (responseSchema ?? this.responseSchema),
      maxTokens: maxTokens ?? this.maxTokens,
      reasoning: reasoning ?? this.reasoning,
      temperature: temperature,
    );
  }
}

enum LlmFinishReason {
  /// The model finished on its own.
  stop,

  /// The model wants tools run; the reply carries [ToolCallPart]s.
  toolCalls,

  /// Output hit the token ceiling and is truncated.
  length,

  /// The model declined the request.
  refusal,

  /// A safety system blocked the reply.
  filtered,
}

class LlmUsage {
  const LlmUsage({this.inputTokens = 0, this.outputTokens = 0});
  final int inputTokens;
  final int outputTokens;
  int get total => inputTokens + outputTokens;

  LlmUsage operator +(LlmUsage other) => LlmUsage(
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
  );
}

class LlmResponse {
  const LlmResponse({
    required this.parts,
    required this.finishReason,
    this.usage = const LlmUsage(),
    this.model,
  });

  final List<LlmPart> parts;
  final LlmFinishReason finishReason;
  final LlmUsage usage;
  final String? model;

  String get text =>
      parts.whereType<TextPart>().map((p) => p.text).join().trim();

  List<ToolCallPart> get toolCalls => parts.whereType<ToolCallPart>().toList();

  /// True when the model declined or was blocked. Callers must check this
  /// before reading [text]: a refusal carries an empty or partial reply, and
  /// treating it as an answer is how a refusal turns into a crash.
  bool get declined =>
      finishReason == LlmFinishReason.refusal ||
      finishReason == LlmFinishReason.filtered;

  LlmMessage toMessage() => LlmMessage(LlmRole.assistant, parts);
}

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
