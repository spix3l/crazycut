part of 'llm_message.dart';

/// One piece of a message. Messages are lists of parts because a single
/// assistant turn routinely mixes prose with tool calls.
sealed class LlmPart {
  const LlmPart();
}
