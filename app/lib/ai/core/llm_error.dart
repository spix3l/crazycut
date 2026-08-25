/// One error taxonomy for every provider (AI-7).
///
/// Adapters map their transport failures and status codes onto these types so
/// callers never branch on a vendor's status codes. Retry policy is decided
/// here, once, rather than per adapter.
library;

sealed class LlmError implements Exception {
  const LlmError(this.message, {this.provider});

  final String message;
  final String? provider;

  /// Whether retrying the identical request could plausibly succeed.
  bool get retryable => false;

  /// How long to wait before a retry, when the provider said.
  Duration? get retryAfter => null;

  @override
  String toString() =>
      provider == null ? message : '$message (provider: $provider)';
}

/// Missing, malformed, or rejected credentials.
class LlmAuthError extends LlmError {
  const LlmAuthError(super.message, {super.provider});
}

/// Rate limited or out of quota.
class LlmRateLimitError extends LlmError {
  const LlmRateLimitError(super.message, {super.provider, this.retryAfterValue});

  final Duration? retryAfterValue;

  @override
  bool get retryable => true;

  @override
  Duration? get retryAfter => retryAfterValue;
}

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

/// The provider's safety layer blocked the request or reply. Retrying the same
/// prompt will fail the same way.
class LlmContentFilteredError extends LlmError {
  const LlmContentFilteredError(super.message, {super.provider, this.category});
  final String? category;
}

/// The endpoint could not be reached, or the connection failed mid-flight.
class LlmTransportError extends LlmError {
  const LlmTransportError(super.message, {super.provider, this.cause});
  final Object? cause;

  @override
  bool get retryable => true;
}

/// The provider answered, but with something we could not use: an unknown model
/// name, a malformed body, a 5xx.
class LlmProviderError extends LlmError {
  const LlmProviderError(
    super.message, {
    super.provider,
    this.statusCode,
    this.isServerFault = false,
  });

  final int? statusCode;
  final bool isServerFault;

  @override
  bool get retryable => isServerFault;
}

/// The model's reply did not satisfy the requested schema after the repair
/// round-trip (AI-9). Distinct from [LlmProviderError] because the transport
/// worked fine — the model simply did not comply.
class LlmSchemaError extends LlmError {
  const LlmSchemaError(super.message, {super.provider, this.rawReply});
  final String? rawReply;
}

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
