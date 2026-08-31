library;

part 'llm_auth_error.dart';
part 'llm_cancelled_error.dart';
part 'llm_content_filtered_error.dart';
part 'llm_context_overflow_error.dart';
part 'llm_provider_error.dart';
part 'llm_rate_limit_error.dart';
part 'llm_schema_error.dart';
part 'llm_transport_error.dart';
/// One error taxonomy for every provider (AI-7).
///
/// Adapters map their transport failures and status codes onto these types so
/// callers never branch on a vendor's status codes. Retry policy is decided
/// here, once, rather than per adapter.
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
