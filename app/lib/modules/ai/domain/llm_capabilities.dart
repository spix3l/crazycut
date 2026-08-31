part of 'llm_provider.dart';

/// What an adapter's backend can actually do (AI-8).
///
/// The core uses these to decide whether a request can go out as written or
/// needs the compatibility path in `schema_fallback.dart`. Adapters must be
/// honest here: claiming a capability that is not there turns a graceful
/// degradation into a runtime failure.
class LlmCapabilities {
  const LlmCapabilities({
    required this.tools,
    required this.jsonSchema,
    required this.streaming,
    this.contextWindow = 128000,
  });

  /// Native function/tool calling.
  final bool tools;

  /// Server-enforced structured output against a JSON Schema.
  final bool jsonSchema;

  final bool streaming;

  /// Total tokens the configured model accepts. Used to refuse oversized
  /// requests before spending money on them.
  final int contextWindow;

  static const conservative = LlmCapabilities(
    tools: false,
    jsonSchema: false,
    streaming: false,
    contextWindow: 8192,
  );
}
