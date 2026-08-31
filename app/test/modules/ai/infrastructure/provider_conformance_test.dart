/// Conformance suite (AI-5, AI-7, acceptance criterion 2).
///
/// One test body, run against every shipped adapter with recorded wire
/// responses. This is what actually keeps "provider-agnostic" honest: if a new
/// adapter maps a refusal to the wrong finish reason, or a 429 to a generic
/// error, it fails here rather than in a feature months later.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:crazycut_app/modules/ai/domain/llm_message.dart';
import 'package:crazycut_app/modules/ai/domain/llm_provider.dart';
import 'package:crazycut_app/modules/ai/infrastructure/anthropic_provider.dart';
import 'package:crazycut_app/modules/ai/infrastructure/ollama_provider.dart';
import 'package:crazycut_app/modules/ai/infrastructure/openai_compatible_provider.dart';

/// The wire shapes each adapter must understand, and the request field each
/// one sends. Everything else in this file is provider-blind.
class AdapterCase {
  const AdapterCase({
    required this.name,
    required this.build,
    required this.plainText,
    required this.withToolCall,
    required this.truncated,
    this.refusal,
  });

  final String name;
  final LlmProvider Function(http.Client) build;

  /// A normal reply saying "hello", reporting 11 input / 5 output tokens.
  final String plainText;

  /// A reply calling `get_weather` with `{"city": "Paris"}`.
  final String withToolCall;

  /// A reply cut short by the output ceiling.
  final String truncated;

  /// A model-level decline, where the provider has the concept.
  final String? refusal;
}

final cases = <AdapterCase>[
  AdapterCase(
    name: 'openai-compatible',
    build: (c) => OpenAiCompatibleProvider(
      baseUrl: 'https://example.test/v1',
      model: 'test-model',
      apiKey: 'k',
      client: c,
    ),
    plainText: jsonEncode({
      'model': 'test-model',
      'choices': [
        {
          'message': {'role': 'assistant', 'content': 'hello'},
          'finish_reason': 'stop',
        },
      ],
      'usage': {'prompt_tokens': 11, 'completion_tokens': 5},
    }),
    withToolCall: jsonEncode({
      'choices': [
        {
          'message': {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {
                  'name': 'get_weather',
                  'arguments': '{"city": "Paris"}',
                },
              },
            ],
          },
          'finish_reason': 'tool_calls',
        },
      ],
    }),
    truncated: jsonEncode({
      'choices': [
        {
          'message': {'content': 'cut off'},
          'finish_reason': 'length',
        },
      ],
    }),
    refusal: jsonEncode({
      'choices': [
        {
          'message': {'content': ''},
          'finish_reason': 'content_filter',
        },
      ],
    }),
  ),
  AdapterCase(
    name: 'anthropic',
    build: (c) => AnthropicProvider(
      model: 'test-model',
      apiKey: 'k',
      baseUrl: 'https://example.test/v1',
      client: c,
    ),
    plainText: jsonEncode({
      'model': 'test-model',
      'content': [
        {'type': 'text', 'text': 'hello'},
      ],
      'stop_reason': 'end_turn',
      'usage': {'input_tokens': 11, 'output_tokens': 5},
    }),
    withToolCall: jsonEncode({
      'content': [
        {
          'type': 'tool_use',
          'id': 'call_1',
          'name': 'get_weather',
          'input': {'city': 'Paris'},
        },
      ],
      'stop_reason': 'tool_use',
    }),
    truncated: jsonEncode({
      'content': [
        {'type': 'text', 'text': 'cut off'},
      ],
      'stop_reason': 'max_tokens',
    }),
    refusal: jsonEncode({
      'content': <dynamic>[],
      'stop_reason': 'refusal',
    }),
  ),
  AdapterCase(
    name: 'ollama',
    build: (c) => OllamaProvider(
      model: 'test-model',
      baseUrl: 'http://example.test',
      client: c,
      // The default declares no tool support; this case exercises the wire
      // mapping for a model that does have it.
      capabilities: const LlmCapabilities(
        tools: true,
        jsonSchema: false,
        streaming: true,
      ),
    ),
    plainText: jsonEncode({
      'model': 'test-model',
      'message': {'role': 'assistant', 'content': 'hello'},
      'done': true,
      'prompt_eval_count': 11,
      'eval_count': 5,
    }),
    withToolCall: jsonEncode({
      'message': {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'function': {
              'name': 'get_weather',
              'arguments': {'city': 'Paris'},
            },
          },
        ],
      },
      'done': true,
    }),
    truncated: jsonEncode({
      'message': {'content': 'cut off'},
      'done': true,
      'done_reason': 'length',
    }),
  ),
];

MockClient replying(String body, {int status = 200, Map<String, String>? headers}) =>
    MockClient((_) async => http.Response(body, status, headers: headers ?? {}));

final request = LlmRequest(messages: [LlmMessage.user('hi')]);

void main() {
  for (final c in cases) {
    group('${c.name} conforms', () {
      test('maps a plain reply', () async {
        final provider = c.build(replying(c.plainText));
        final res = await provider.complete(request);
        expect(res.text, 'hello');
        expect(res.finishReason, LlmFinishReason.stop);
        expect(res.toolCalls, isEmpty);
        expect(res.declined, isFalse);
        expect(res.usage.inputTokens, 11);
        expect(res.usage.outputTokens, 5);
      });

      test('maps a tool call', () async {
        final provider = c.build(replying(c.withToolCall));
        final res = await provider.complete(request);
        expect(res.finishReason, LlmFinishReason.toolCalls);
        final call = res.toolCalls.single;
        expect(call.name, 'get_weather');
        expect(call.args, {'city': 'Paris'});
        expect(call.id, isNotEmpty);
      });

      test('maps a truncated reply', () async {
        final provider = c.build(replying(c.truncated));
        final res = await provider.complete(request);
        expect(res.finishReason, LlmFinishReason.length);
      });

      if (c.refusal != null) {
        test('maps a decline so callers can see it before reading content', () async {
          final provider = c.build(replying(c.refusal!));
          final res = await provider.complete(request);
          expect(res.declined, isTrue);
        });
      }

      test('maps 401 to an auth error', () async {
        final provider = c.build(
          replying(
            jsonEncode({
              'error': {'message': 'bad key'},
            }),
            status: 401,
          ),
        );
        await expectLater(
          provider.complete(request),
          throwsA(
            isA<LlmAuthError>().having(
              (e) => e.message,
              'message',
              contains('bad key'),
            ),
          ),
        );
      });

      test('maps 429 to a retryable rate-limit error carrying retry-after', () async {
        final provider = c.build(
          replying(
            jsonEncode({
              'error': {'message': 'slow down'},
            }),
            status: 429,
            headers: {'retry-after': '7'},
          ),
        );
        await expectLater(
          provider.complete(request),
          throwsA(
            isA<LlmRateLimitError>()
                .having((e) => e.retryable, 'retryable', isTrue)
                .having(
                  (e) => e.retryAfter,
                  'retryAfter',
                  const Duration(seconds: 7),
                ),
          ),
        );
      });

      test('maps 500 to a retryable provider error', () async {
        final provider = c.build(replying('upstream exploded', status: 500));
        await expectLater(
          provider.complete(request),
          throwsA(
            isA<LlmProviderError>().having(
              (e) => e.retryable,
              'retryable',
              isTrue,
            ),
          ),
        );
      });

      test('maps a context-length 400 to a context overflow error', () async {
        final provider = c.build(
          replying(
            jsonEncode({
              'error': {
                'message':
                    "This model's maximum context length is 8192 tokens.",
              },
            }),
            status: 400,
          ),
        );
        await expectLater(
          provider.complete(request),
          throwsA(isA<LlmContextOverflowError>()),
        );
      });

      test('maps an unreachable endpoint to a transport error', () async {
        final provider = c.build(
          MockClient((_) async => throw const SocketishFailure()),
        );
        await expectLater(
          provider.complete(request),
          throwsA(isA<LlmTransportError>()),
        );
      });

      test('reports a provider id on every error', () async {
        final provider = c.build(replying('nope', status: 401));
        try {
          await provider.complete(request);
          fail('expected a throw');
        } on LlmError catch (e) {
          expect(e.provider, provider.id);
        }
      });
    });
  }

  group('adapters send credentials the way their API expects', () {
    test('openai-compatible uses a bearer token', () async {
      late Map<String, String> sent;
      final provider = OpenAiCompatibleProvider(
        baseUrl: 'https://example.test/v1',
        model: 'm',
        apiKey: 'secret',
        client: MockClient((r) async {
          sent = r.headers;
          return http.Response(cases[0].plainText, 200);
        }),
      );
      await provider.complete(request);
      expect(sent['authorization'], 'Bearer secret');
    });

    test('anthropic uses x-api-key and a version header', () async {
      late Map<String, String> sent;
      final provider = AnthropicProvider(
        model: 'm',
        apiKey: 'secret',
        baseUrl: 'https://example.test/v1',
        client: MockClient((r) async {
          sent = r.headers;
          return http.Response(cases[1].plainText, 200);
        }),
      );
      await provider.complete(request);
      expect(sent['x-api-key'], 'secret');
      expect(sent['anthropic-version'], isNotEmpty);
    });

    test('ollama sends no credentials at all', () async {
      late Map<String, String> sent;
      final provider = OllamaProvider(
        model: 'm',
        baseUrl: 'http://example.test',
        client: MockClient((r) async {
          sent = r.headers;
          return http.Response(cases[2].plainText, 200);
        }),
      );
      await provider.complete(request);
      expect(sent.containsKey('authorization'), isFalse);
      expect(sent.containsKey('x-api-key'), isFalse);
    });
  });

  group('request shaping', () {
    test('anthropic lifts system turns out of the message list', () async {
      late Map<String, dynamic> body;
      final provider = AnthropicProvider(
        model: 'm',
        apiKey: 'k',
        baseUrl: 'https://example.test/v1',
        client: MockClient((r) async {
          body = jsonDecode(r.body) as Map<String, dynamic>;
          return http.Response(cases[1].plainText, 200);
        }),
      );
      await provider.complete(
        LlmRequest(
          messages: [LlmMessage.system('be terse'), LlmMessage.user('hi')],
        ),
      );
      expect(body['system'], 'be terse');
      expect((body['messages'] as List).length, 1);
    });

    test('openai-compatible keeps system turns inline', () async {
      late Map<String, dynamic> body;
      final provider = OpenAiCompatibleProvider(
        baseUrl: 'https://example.test/v1',
        model: 'm',
        client: MockClient((r) async {
          body = jsonDecode(r.body) as Map<String, dynamic>;
          return http.Response(cases[0].plainText, 200);
        }),
      );
      await provider.complete(
        LlmRequest(
          messages: [LlmMessage.system('be terse'), LlmMessage.user('hi')],
        ),
      );
      expect((body['messages'] as List).first['role'], 'system');
    });

    test('openai-compatible splits tool results into one message each', () async {
      late Map<String, dynamic> body;
      final provider = OpenAiCompatibleProvider(
        baseUrl: 'https://example.test/v1',
        model: 'm',
        client: MockClient((r) async {
          body = jsonDecode(r.body) as Map<String, dynamic>;
          return http.Response(cases[0].plainText, 200);
        }),
      );
      await provider.complete(
        LlmRequest(
          messages: [
            LlmMessage.user('hi'),
            LlmMessage.toolResults(const [
              ToolResultPart(callId: 'a', content: '1'),
              ToolResultPart(callId: 'b', content: '2'),
            ]),
          ],
        ),
      );
      final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
      final toolMessages = messages.where((m) => m['role'] == 'tool').toList();
      expect(toolMessages.length, 2);
      expect(toolMessages.first['tool_call_id'], 'a');
    });

    test('anthropic keeps tool results as blocks in one turn', () async {
      late Map<String, dynamic> body;
      final provider = AnthropicProvider(
        model: 'm',
        apiKey: 'k',
        baseUrl: 'https://example.test/v1',
        client: MockClient((r) async {
          body = jsonDecode(r.body) as Map<String, dynamic>;
          return http.Response(cases[1].plainText, 200);
        }),
      );
      await provider.complete(
        LlmRequest(
          messages: [
            LlmMessage.user('hi'),
            LlmMessage.toolResults(const [
              ToolResultPart(callId: 'a', content: '1'),
              ToolResultPart(callId: 'b', content: '2', isError: true),
            ]),
          ],
        ),
      );
      final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
      final blocks = (messages.last['content'] as List)
          .cast<Map<String, dynamic>>();
      expect(blocks.length, 2);
      expect(blocks.first['type'], 'tool_result');
      expect(blocks.last['is_error'], isTrue);
    });

    test('sampling parameters are omitted unless a caller sets one', () async {
      late Map<String, dynamic> body;
      final provider = AnthropicProvider(
        model: 'm',
        apiKey: 'k',
        baseUrl: 'https://example.test/v1',
        client: MockClient((r) async {
          body = jsonDecode(r.body) as Map<String, dynamic>;
          return http.Response(cases[1].plainText, 200);
        }),
      );
      await provider.complete(request);
      // Several current models reject sampling parameters outright, so an
      // adapter that always sends them breaks on those models.
      expect(body.containsKey('temperature'), isFalse);
    });
  });
}

/// Stands in for a connection failure without depending on dart:io in a test
/// that otherwise never touches the network.
class SocketishFailure implements Exception {
  const SocketishFailure();
  @override
  String toString() => 'connection refused';
}
