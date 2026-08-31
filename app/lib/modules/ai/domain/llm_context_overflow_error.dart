part of 'llm_error.dart';

/// The request does not fit the model's context window. Not retryable as-is —
/// the caller must send less.
class LlmContextOverflowError extends LlmError {
  const LlmContextOverflowError(
    super.message, {
    super.provider,
    this.requestedTokens,
    this.contextWindow,
  });

  final int? requestedTokens;
  final int? contextWindow;
}
