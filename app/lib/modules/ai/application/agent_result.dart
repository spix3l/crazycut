part of 'agent.dart';

class AgentResult {
  AgentResult({
    required this.messages,
    required this.finalResponse,
    required this.usage,
    required this.turns,
    required this.hitIterationCap,
  });

  /// The full conversation, ready to continue from.
  final List<LlmMessage> messages;
  final LlmResponse finalResponse;
  final LlmUsage usage;
  final List<AgentTurn> turns;

  /// True when the loop stopped because it ran out of iterations rather than
  /// because the model was finished — the answer may be incomplete.
  final bool hitIterationCap;

  String get text => finalResponse.text;
}
