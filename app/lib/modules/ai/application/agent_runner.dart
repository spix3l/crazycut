part of 'agent.dart';

class AgentRunner {
  AgentRunner({
    required this.provider,
    this.tools = const [],
    this.maxIterations = 8,
    this.reasoning = LlmReasoning.auto,
    this.maxTokens = 8192,
  });

  final LlmProvider provider;
  final List<CcTool> tools;

  /// Hard stop, so a model that keeps calling tools cannot spin forever
  /// (AI-13).
  final int maxIterations;

  final LlmReasoning reasoning;
  final int maxTokens;

  List<LlmToolDef> get _defs => [
    for (final t in tools)
      LlmToolDef(name: t.name, description: t.description, schema: t.schema),
  ];

  Future<AgentResult> run(
    List<LlmMessage> messages, {
    CancellationToken? cancel,
    void Function(AgentTurn turn)? onTurn,
  }) async {
    final history = List<LlmMessage>.of(messages);
    final turns = <AgentTurn>[];
    var usage = const LlmUsage();
    final native = provider.capabilities.tools;

    LlmResponse? last;

    for (var i = 0; i < maxIterations; i++) {
      cancel?.throwIfCancelled();

      var request = LlmRequest(
        // A snapshot, not the live list: `history` keeps growing as the loop
        // runs, and a provider that holds onto a request (a retry, the session
        // log) must not see turns that had not happened when it was called.
        messages: List.unmodifiable(history),
        tools: _defs,
        maxTokens: maxTokens,
        reasoning: reasoning,
      );
      // A backend without native tool calling gets the tools described in the
      // prompt instead; everything downstream is identical.
      if (!native && tools.isNotEmpty) {
        request = describeToolsInPrompt(request);
      }

      var response = await withRetry(
        () => provider.complete(request, cancel: cancel),
      );
      if (!native && tools.isNotEmpty) {
        response = parseToolCallsFromText(response);
      }
      usage = usage + response.usage;
      last = response;

      // A refusal or a filter block ends the loop: retrying the same prompt
      // fails the same way, and the caller needs to see it as a decline rather
      // than as an empty answer.
      if (response.declined) {
        history.add(response.toMessage());
        final turn = AgentTurn(index: i, response: response, toolCalls: const []);
        turns.add(turn);
        onTurn?.call(turn);
        return AgentResult(
          messages: history,
          finalResponse: response,
          usage: usage,
          turns: turns,
          hitIterationCap: false,
        );
      }

      final calls = response.toolCalls;
      history.add(response.toMessage());

      if (calls.isEmpty) {
        final turn = AgentTurn(index: i, response: response, toolCalls: const []);
        turns.add(turn);
        onTurn?.call(turn);
        return AgentResult(
          messages: history,
          finalResponse: response,
          usage: usage,
          turns: turns,
          hitIterationCap: false,
        );
      }

      // Every requested call runs, and every result goes back in ONE turn.
      // Splitting them across turns teaches models to stop calling tools in
      // parallel, which costs a round-trip per call from then on (AI-11).
      final results = <ToolResultPart>[];
      final logged =
          <({String name, Map<String, dynamic> args, String result, bool isError})>[];

      for (final call in calls) {
        cancel?.throwIfCancelled();
        final tool = tools.where((t) => t.name == call.name).firstOrNull;
        String output;
        var isError = false;

        if (tool == null) {
          isError = true;
          output =
              'No tool named "${call.name}". Available tools: '
              '${tools.map((t) => t.name).join(', ')}.';
        } else {
          try {
            output = await tool.run(call.args);
          } on Object catch (e) {
            // A throwing tool must never take the loop down; the model gets
            // told and can try something else (AI-12).
            isError = true;
            output = 'The tool failed: $e';
          }
        }

        results.add(
          ToolResultPart(
            callId: call.id,
            content: output,
            isError: isError,
          ),
        );
        logged.add((
          name: call.name,
          args: call.args,
          result: output,
          isError: isError,
        ));
      }

      history.add(
        native
            ? LlmMessage.toolResults(results)
            : renderToolResultsAsText(results),
      );

      final turn = AgentTurn(index: i, response: response, toolCalls: logged);
      turns.add(turn);
      onTurn?.call(turn);
    }

    // Out of iterations. Report it rather than pretending the last tool-calling
    // turn was an answer.
    return AgentResult(
      messages: history,
      finalResponse:
          last ??
          const LlmResponse(parts: [], finishReason: LlmFinishReason.stop),
      usage: usage,
      turns: turns,
      hitIterationCap: true,
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}

/// Convenience for tools that want to hand back structured data.
String encodeToolResult(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);
