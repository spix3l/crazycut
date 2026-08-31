part of 'llm_message.dart';

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
