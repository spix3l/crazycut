part of 'llm_message.dart';

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
