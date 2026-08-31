part of 'llm_error.dart';

/// The provider's safety layer blocked the request or reply. Retrying the same
/// prompt will fail the same way.
class LlmContentFilteredError extends LlmError {
  const LlmContentFilteredError(super.message, {super.provider, this.category});
  final String? category;
}
