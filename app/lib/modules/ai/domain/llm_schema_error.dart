part of 'llm_error.dart';

/// The model's reply did not satisfy the requested schema after the repair
/// round-trip (AI-9). Distinct from [LlmProviderError] because the transport
/// worked fine — the model simply did not comply.
class LlmSchemaError extends LlmError {
  const LlmSchemaError(super.message, {super.provider, this.rawReply});
  final String? rawReply;
}
