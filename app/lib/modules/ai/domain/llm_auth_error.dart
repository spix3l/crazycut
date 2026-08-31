part of 'llm_error.dart';

/// Missing, malformed, or rejected credentials.
class LlmAuthError extends LlmError {
  const LlmAuthError(super.message, {super.provider});
}
