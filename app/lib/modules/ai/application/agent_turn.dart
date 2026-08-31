part of 'agent.dart';

/// One entry in the session log (AI-14).
class AgentTurn {
  AgentTurn({
    required this.index,
    required this.response,
    required this.toolCalls,
  });

  final int index;
  final LlmResponse response;
  final List<({String name, Map<String, dynamic> args, String result, bool isError})>
  toolCalls;
}
