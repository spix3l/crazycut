part of 'llm_message.dart';

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
