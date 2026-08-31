part of 'llm_error.dart';

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
