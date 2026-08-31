part of 'llm_error.dart';

/// Rate limited or out of quota.
class LlmRateLimitError extends LlmError {
  const LlmRateLimitError(super.message, {super.provider, this.retryAfterValue});

  final Duration? retryAfterValue;

  @override
  bool get retryable => true;

  @override
  Duration? get retryAfter => retryAfterValue;
}
