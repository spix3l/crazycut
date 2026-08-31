import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/ai/application/agent.dart';
import 'package:crazycut_app/modules/ai/domain/llm_message.dart';
import 'package:crazycut_app/modules/ai/domain/llm_provider.dart';
import 'package:crazycut_app/modules/ai/domain/schema_fallback.dart';
import 'package:crazycut_app/modules/ai/domain/tool_fallback.dart';

/// A provider that replays scripted replies. Lets the core and the agent loop
/// be tested without a network or a vendor.
class FakeProvider extends LlmProvider {
  FakeProvider(
    this.replies, {
    LlmCapabilities? capabilities,
  }) : _capabilities =
           capabilities ??
           const LlmCapabilities(
             tools: true,
             jsonSchema: true,
             streaming: false,
           );

  final List<LlmResponse> replies;
  final LlmCapabilities _capabilities;
  final List<LlmRequest> seen = [];
  int _index = 0;

  @override
  String get id => 'fake';
  @override
  String get displayName => 'Fake';
  @override
  String get model => 'fake-1';
  @override
  LlmCapabilities get capabilities => _capabilities;

  @override
  Future<LlmResponse> complete(
    LlmRequest request, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    seen.add(request);
    if (_index >= replies.length) {
      throw StateError('FakeProvider ran out of scripted replies');
    }
    return replies[_index++];
  }

  @override
  Stream<LlmDelta> stream(LlmRequest request, {CancellationToken? cancel}) =>
      Stream.fromFuture(complete(request, cancel: cancel)).map(LlmDelta.done);
}

LlmResponse textReply(String text) => LlmResponse(
  parts: [TextPart(text)],
  finishReason: LlmFinishReason.stop,
);

const candidateSchema = {
  'type': 'object',
  'properties': {
    'title': {'type': 'string'},
    'startSec': {'type': 'number'},
  },
  'required': ['title', 'startSec'],
};

void main() {
  group('extractJson', () {
    test('reads a bare JSON object', () {
      expect(extractJson('{"a": 1}'), {'a': 1});
    });

    test('reads JSON wrapped in prose', () {
      final value = extractJson(
        'Sure! Here are the results:\n{"a": 1, "b": [2, 3]}\nHope that helps.',
      );
      expect(value, {
        'a': 1,
        'b': [2, 3],
      });
    });

    test('reads JSON inside a fenced code block', () {
      expect(extractJson('```json\n{"a": 1}\n```'), {'a': 1});
    });

    test('is not fooled by braces inside strings', () {
      final value = extractJson('prose {"title": "a } b", "n": 1} more');
      expect(value, {'title': 'a } b', 'n': 1});
    });

    test('reads a top-level array', () {
      expect(extractJson('[{"a": 1}]'), [
        {'a': 1},
      ]);
    });

    test('returns null when there is no JSON', () {
      expect(extractJson('I could not do that.'), isNull);
      expect(extractJson(''), isNull);
    });
  });

  group('validateAgainstSchema', () {
    test('accepts a conforming object', () {
      expect(
        validateAgainstSchema({'title': 'x', 'startSec': 1}, candidateSchema),
        isNull,
      );
    });

    test('names a missing required field', () {
      final problem = validateAgainstSchema({'title': 'x'}, candidateSchema);
      expect(problem, contains('startSec'));
    });

    test('names a wrong type, with its path', () {
      final problem = validateAgainstSchema({
        'title': 5,
        'startSec': 1,
      }, candidateSchema);
      expect(problem, contains('value.title'));
      expect(problem, contains('string'));
    });

    test('checks array items', () {
      final schema = {
        'type': 'array',
        'items': candidateSchema,
      };
      final problem = validateAgainstSchema([
        {'title': 'ok', 'startSec': 0},
        {'title': 'bad'},
      ], schema);
      expect(problem, contains('value[1]'));
    });
  });

  group('completeJson', () {
    final request = LlmRequest(messages: [LlmMessage.user('go')]);

    test('uses the native path when the provider enforces schema', () async {
      final provider = FakeProvider([textReply('{"title":"a","startSec":1}')]);
      final value = await completeJson(
        provider,
        request,
        schema: candidateSchema,
      );
      expect(value, {'title': 'a', 'startSec': 1});
      // Native path: the schema rides on the request, not in the prompt.
      expect(provider.seen.single.responseSchema, candidateSchema);
      expect(provider.seen.single.messages.length, 1);
    });

    test('injects the schema when the provider cannot enforce it', () async {
      final provider = FakeProvider(
        [textReply('Here you go:\n{"title":"a","startSec":1}')],
        capabilities: const LlmCapabilities(
          tools: false,
          jsonSchema: false,
          streaming: false,
        ),
      );
      final value = await completeJson(
        provider,
        request,
        schema: candidateSchema,
      );
      expect(value, {'title': 'a', 'startSec': 1});
      expect(provider.seen.single.responseSchema, isNull);
      // The schema was taught in the prompt instead.
      expect(
        provider.seen.single.messages.any(
          (m) => m.role == LlmRole.system && m.text.contains('startSec'),
        ),
        isTrue,
      );
    });

    test('repairs a non-conforming reply in one extra round-trip', () async {
      final provider = FakeProvider(
        [
          textReply('{"title": "missing the number"}'),
          textReply('{"title": "fixed", "startSec": 4}'),
        ],
        capabilities: const LlmCapabilities(
          tools: false,
          jsonSchema: false,
          streaming: false,
        ),
      );
      final value = await completeJson(
        provider,
        request,
        schema: candidateSchema,
      );
      expect(value, {'title': 'fixed', 'startSec': 4});
      expect(provider.seen.length, 2);
      // The repair turn tells the model exactly what was wrong — a blind retry
      // is markedly less reliable.
      expect(provider.seen.last.messages.last.text, contains('startSec'));
    });

    test('throws a schema error when the repair also fails', () async {
      final provider = FakeProvider(
        [textReply('nope'), textReply('still nope')],
        capabilities: const LlmCapabilities(
          tools: false,
          jsonSchema: false,
          streaming: false,
        ),
      );
      await expectLater(
        completeJson(provider, request, schema: candidateSchema),
        throwsA(isA<LlmSchemaError>()),
      );
    });

    test('surfaces a refusal as a decline, not as bad JSON', () async {
      final provider = FakeProvider([
        const LlmResponse(parts: [], finishReason: LlmFinishReason.refusal),
      ]);
      await expectLater(
        completeJson(provider, request, schema: candidateSchema),
        throwsA(isA<LlmContentFilteredError>()),
      );
    });
  });

  group('text tool protocol', () {
    test('parses calls out of a reply', () {
      final parsed = parseToolCallsFromText(
        textReply(
          'Let me look.\n'
          'TOOL_CALL: {"name": "list_clips", "arguments": {"trackId": "v1"}}',
        ),
      );
      expect(parsed.finishReason, LlmFinishReason.toolCalls);
      expect(parsed.toolCalls.single.name, 'list_clips');
      expect(parsed.toolCalls.single.args, {'trackId': 'v1'});
      expect(parsed.text, 'Let me look.');
    });

    test('parses several calls from one reply', () {
      final parsed = parseToolCallsFromText(
        textReply(
          'TOOL_CALL: {"name": "a", "arguments": {}}\n'
          'TOOL_CALL: {"name": "b", "arguments": {}}',
        ),
      );
      expect(parsed.toolCalls.map((c) => c.name), ['a', 'b']);
    });

    test('leaves a malformed call as prose rather than inventing arguments', () {
      final parsed = parseToolCallsFromText(
        textReply('TOOL_CALL: not json at all'),
      );
      expect(parsed.finishReason, LlmFinishReason.stop);
      expect(parsed.toolCalls, isEmpty);
    });

    test('passes a plain reply through untouched', () {
      final response = textReply('all done');
      expect(identical(parseToolCallsFromText(response), response), isTrue);
    });
  });

  group('AgentRunner', () {
    CcTool echoTool({String name = 'echo'}) => InlineTool(
      name: name,
      description: 'Echoes its input back.',
      schema: const {
        'type': 'object',
        'properties': {
          'value': {'type': 'string'},
        },
      },
      handler: (args) async => 'echoed:${args['value']}',
    );

    test('runs a tool and feeds the result back', () async {
      final provider = FakeProvider([
        const LlmResponse(
          parts: [
            ToolCallPart(id: 't1', name: 'echo', args: {'value': 'hi'}),
          ],
          finishReason: LlmFinishReason.toolCalls,
        ),
        textReply('done'),
      ]);

      final result = await AgentRunner(
        provider: provider,
        tools: [echoTool()],
      ).run([LlmMessage.user('go')]);

      expect(result.text, 'done');
      expect(result.turns.first.toolCalls.single.result, 'echoed:hi');
      expect(result.hitIterationCap, isFalse);
    });

    test('returns every result of a parallel turn in a single message', () async {
      final provider = FakeProvider([
        const LlmResponse(
          parts: [
            ToolCallPart(id: 't1', name: 'echo', args: {'value': 'a'}),
            ToolCallPart(id: 't2', name: 'echo', args: {'value': 'b'}),
          ],
          finishReason: LlmFinishReason.toolCalls,
        ),
        textReply('done'),
      ]);

      await AgentRunner(
        provider: provider,
        tools: [echoTool()],
      ).run([LlmMessage.user('go')]);

      // Splitting results across turns teaches models to stop calling tools in
      // parallel, so this shape is load-bearing rather than cosmetic (AI-11).
      final followUp = provider.seen.last.messages.last;
      expect(followUp.parts.whereType<ToolResultPart>().length, 2);
    });

    test('turns a throwing tool into an error result, not a crash', () async {
      final provider = FakeProvider([
        const LlmResponse(
          parts: [ToolCallPart(id: 't1', name: 'boom', args: {})],
          finishReason: LlmFinishReason.toolCalls,
        ),
        textReply('recovered'),
      ]);

      final result = await AgentRunner(
        provider: provider,
        tools: [
          InlineTool(
            name: 'boom',
            description: 'Always fails.',
            schema: const {'type': 'object', 'properties': {}},
            handler: (_) async => throw StateError('nope'),
          ),
        ],
      ).run([LlmMessage.user('go')]);

      expect(result.text, 'recovered');
      expect(result.turns.first.toolCalls.single.isError, isTrue);
      final sent = provider.seen.last.messages.last.parts
          .whereType<ToolResultPart>()
          .single;
      expect(sent.isError, isTrue);
      expect(sent.content, contains('nope'));
    });

    test('tells the model when it invents a tool', () async {
      final provider = FakeProvider([
        const LlmResponse(
          parts: [ToolCallPart(id: 't1', name: 'nonexistent', args: {})],
          finishReason: LlmFinishReason.toolCalls,
        ),
        textReply('ok'),
      ]);

      final result = await AgentRunner(
        provider: provider,
        tools: [echoTool()],
      ).run([LlmMessage.user('go')]);

      expect(result.turns.first.toolCalls.single.isError, isTrue);
      expect(result.turns.first.toolCalls.single.result, contains('echo'));
    });

    test('stops at the iteration cap and says so', () async {
      LlmResponse callAgain() => const LlmResponse(
        parts: [ToolCallPart(id: 't', name: 'echo', args: {'value': 'x'})],
        finishReason: LlmFinishReason.toolCalls,
      );
      final provider = FakeProvider(List.generate(5, (_) => callAgain()));

      final result = await AgentRunner(
        provider: provider,
        tools: [echoTool()],
        maxIterations: 3,
      ).run([LlmMessage.user('go')]);

      expect(result.hitIterationCap, isTrue);
      expect(provider.seen.length, 3);
    });

    test('stops immediately on a refusal', () async {
      final provider = FakeProvider([
        const LlmResponse(parts: [], finishReason: LlmFinishReason.refusal),
      ]);

      final result = await AgentRunner(
        provider: provider,
        tools: [echoTool()],
      ).run([LlmMessage.user('go')]);

      expect(result.finalResponse.declined, isTrue);
      expect(provider.seen.length, 1);
    });

    test('cancellation stops the loop between turns', () async {
      final cancel = CancellationToken();
      final provider = FakeProvider([
        const LlmResponse(
          parts: [ToolCallPart(id: 't1', name: 'stop', args: {})],
          finishReason: LlmFinishReason.toolCalls,
        ),
        textReply('never reached'),
      ]);

      await expectLater(
        AgentRunner(
          provider: provider,
          tools: [
            InlineTool(
              name: 'stop',
              description: 'Cancels the run.',
              schema: const {'type': 'object', 'properties': {}},
              handler: (_) async {
                cancel.cancel();
                return 'cancelled';
              },
            ),
          ],
        ).run([LlmMessage.user('go')], cancel: cancel),
        throwsA(isA<LlmCancelledError>()),
      );
      expect(provider.seen.length, 1);
    });

    test('drives a tool-less provider through the text protocol', () async {
      final provider = FakeProvider(
        [
          textReply('TOOL_CALL: {"name": "echo", "arguments": {"value": "hi"}}'),
          textReply('done'),
        ],
        capabilities: const LlmCapabilities(
          tools: false,
          jsonSchema: false,
          streaming: false,
        ),
      );

      final result = await AgentRunner(
        provider: provider,
        tools: [echoTool()],
      ).run([LlmMessage.user('go')]);

      expect(result.text, 'done');
      expect(result.turns.first.toolCalls.single.result, 'echoed:hi');
      // Tools were described in the prompt rather than sent as definitions.
      expect(provider.seen.first.tools, isEmpty);
      expect(
        provider.seen.first.messages.any((m) => m.text.contains('TOOL_CALL:')),
        isTrue,
      );
    });
  });
}
