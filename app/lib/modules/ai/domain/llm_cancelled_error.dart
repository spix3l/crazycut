part of 'llm_error.dart';

/// The caller cancelled. Never surfaced as a failure in the UI.
class LlmCancelledError extends LlmError {
  const LlmCancelledError({super.provider}) : super('Cancelled');
}

/// Runs [action], retrying once on a retryable failure — the same single-retry
/// policy the export worker uses (EXP-11). Anything not retryable propagates
/// immediately, so a bad key fails fast instead of failing twice.
Future<T> withRetry<T>(
  Future<T> Function() action, {
  Duration maxBackoff = const Duration(seconds: 30),
}) async {
  try {
    return await action();
  } on LlmError catch (e) {
    if (!e.retryable) rethrow;
    final wait = e.retryAfter ?? const Duration(seconds: 2);
    await Future<void>.delayed(wait > maxBackoff ? maxBackoff : wait);
    return await action();
  }
}
