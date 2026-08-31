part of 'llm_error.dart';

/// The endpoint could not be reached, or the connection failed mid-flight.
class LlmTransportError extends LlmError {
  const LlmTransportError(super.message, {super.provider, this.cause});
  final Object? cause;

  @override
  bool get retryable => true;
}
