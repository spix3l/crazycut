part of 'llm_message.dart';

class LlmRequest {
  const LlmRequest({
    required this.messages,
    this.tools = const [],
    this.responseSchema,
    this.maxTokens = 8192,
    this.reasoning = LlmReasoning.auto,
    this.temperature,
  });

  final List<LlmMessage> messages;
  final List<LlmToolDef> tools;

  /// When set, the reply must be a single JSON value matching this schema.
  /// Providers without server-side enforcement are handled by the core's
  /// fallback rather than by callers (AI-9).
  final Map<String, dynamic>? responseSchema;

  final int maxTokens;
  final LlmReasoning reasoning;

  /// Only sent by adapters whose provider still accepts it. Several current
  /// models reject sampling parameters outright, so this stays unset by default.
  final double? temperature;

  LlmRequest copyWith({
    List<LlmMessage>? messages,
    List<LlmToolDef>? tools,
    Map<String, dynamic>? responseSchema,
    bool clearResponseSchema = false,
    int? maxTokens,
    LlmReasoning? reasoning,
  }) {
    return LlmRequest(
      messages: messages ?? this.messages,
      tools: tools ?? this.tools,
      responseSchema: clearResponseSchema
          ? null
          : (responseSchema ?? this.responseSchema),
      maxTokens: maxTokens ?? this.maxTokens,
      reasoning: reasoning ?? this.reasoning,
      temperature: temperature,
    );
  }
}
