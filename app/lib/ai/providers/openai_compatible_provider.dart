/// Chat-completions adapter (AI-10).
///
/// Points at anything speaking OpenAI's `/v1/chat/completions`: OpenAI itself,
/// OpenRouter, Groq, Together, LM Studio, vLLM, llama.cpp's server, and most
/// self-hosted stacks. Because that shape is the ecosystem's lingua franca,
/// this one adapter covers the large majority of what users will point us at —
/// which is exactly why the base URL is configuration rather than a constant.
library;

import 'dart:convert';

import 'package:crazycut_app/ai/core/llm_message.dart';
import 'package:crazycut_app/ai/core/llm_provider.dart';
import 'package:crazycut_app/ai/providers/http_provider.dart';

class OpenAiCompatibleProvider extends HttpLlmProvider {
  OpenAiCompatibleProvider({
    required super.baseUrl,
    required this.model,
    this.apiKey,
    LlmCapabilities? capabilities,
    super.client,
  }) : _capabilities = capabilities ?? defaultCapabilities;

  /// What a hosted OpenAI-compatible endpoint typically supports. Local shims
  /// often support less, so this is a default the user can correct in settings
  /// rather than a promise (AI-8).
  static const defaultCapabilities = LlmCapabilities(
    tools: true,
    jsonSchema: true,
    streaming: true,
    contextWindow: 128000,
  );

  @override
  final String model;
  final String? apiKey;
  final LlmCapabilities _capabilities;

  @override
  String get id => 'openai-compatible';

  @override
  String get displayName => 'OpenAI-compatible';

  @override
  LlmCapabilities get capabilities => _capabilities;

  @override
  Map<String, String> headers() => {
    if (apiKey != null && apiKey!.isNotEmpty)
      'authorization': 'Bearer $apiKey',
  };

  Map<String, dynamic> _body(LlmRequest request, {required bool stream}) {
    final body = <String, dynamic>{
      'model': model,
      'messages': _encodeMessages(request.messages),
      'max_tokens': request.maxTokens,
      if (stream) 'stream': true,
      if (stream) 'stream_options': {'include_usage': true},
      if (request.temperature != null) 'temperature': request.temperature,
    };

    if (request.tools.isNotEmpty) {
      body['tools'] = [
        for (final t in request.tools)
          {
            'type': 'function',
            'function': {
              'name': t.name,
              'description': t.description,
              'parameters': t.schema,
            },
          },
      ];
    }

    final schema = request.responseSchema;
    if (schema != null) {
      body['response_format'] = {
        'type': 'json_schema',
        'json_schema': {'name': 'result', 'schema': schema, 'strict': false},
      };
    }

    // Reasoning is an intent, not a number (AI-6). This family expresses depth
    // as an effort string; backends that do not know the field ignore it.
    switch (request.reasoning) {
      case LlmReasoning.none:
        break;
      case LlmReasoning.auto:
        body['reasoning_effort'] = 'medium';
      case LlmReasoning.deep:
        body['reasoning_effort'] = 'high';
    }
    return body;
  }

  /// Flattens our part-based messages into the role/content pairs this API
  /// wants. Tool results are the awkward case: we carry them as parts of one
  /// user turn (AI-11), while this API wants one `tool` message each.
  List<Map<String, dynamic>> _encodeMessages(List<LlmMessage> messages) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final toolResults = m.parts.whereType<ToolResultPart>().toList();
      if (toolResults.isNotEmpty) {
        for (final r in toolResults) {
          out.add({
            'role': 'tool',
            'tool_call_id': r.callId,
            'content': r.isError ? 'ERROR: ${r.content}' : r.content,
          });
        }
        continue;
      }

      final calls = m.parts.whereType<ToolCallPart>().toList();
      final text = m.text;
      out.add({
        'role': switch (m.role) {
          LlmRole.system => 'system',
          LlmRole.user => 'user',
          LlmRole.assistant => 'assistant',
        },
        'content': text.isEmpty ? null : text,
        if (calls.isNotEmpty)
          'tool_calls': [
            for (final c in calls)
              {
                'id': c.id,
                'type': 'function',
                'function': {
                  'name': c.name,
                  'arguments': jsonEncode(c.args),
                },
              },
          ],
      });
    }
    return out;
  }

  @override
  Future<LlmResponse> complete(
    LlmRequest request, {
    CancellationToken? cancel,
  }) async {
    final json = await postJson(
      '/chat/completions',
      _body(request, stream: false),
      cancel: cancel,
    );
    return _decode(json);
  }

  @override
  Stream<LlmDelta> stream(
    LlmRequest request, {
    CancellationToken? cancel,
  }) async* {
    final buffer = StringBuffer();
    final calls = <int, _PartialCall>{};
    var finish = LlmFinishReason.stop;
    var usage = const LlmUsage();

    await for (final frame in postSse(
      '/chat/completions',
      _body(request, stream: true),
      cancel: cancel,
    )) {
      final u = frame['usage'];
      if (u is Map) usage = _usage(u);

      final choices = frame['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final choice = choices.first as Map<String, dynamic>;

      final reason = choice['finish_reason'];
      if (reason is String) finish = _finishReason(reason);

      final delta = choice['delta'];
      if (delta is! Map) continue;

      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        buffer.write(content);
        yield LlmDelta.text(content);
      }

      final toolCalls = delta['tool_calls'];
      if (toolCalls is List) {
        for (final raw in toolCalls) {
          if (raw is! Map) continue;
          final index = (raw['index'] as num?)?.toInt() ?? 0;
          final partial = calls.putIfAbsent(index, _PartialCall.new);
          if (raw['id'] is String) partial.id = raw['id'] as String;
          final fn = raw['function'];
          if (fn is Map) {
            if (fn['name'] is String) partial.name = fn['name'] as String;
            if (fn['arguments'] is String) {
              partial.arguments.write(fn['arguments'] as String);
            }
          }
        }
      }
    }

    final parts = <LlmPart>[
      if (buffer.isNotEmpty) TextPart(buffer.toString()),
      for (final entry in calls.entries)
        ToolCallPart(
          id: entry.value.id ?? 'call-${entry.key}',
          name: entry.value.name ?? '',
          args: _decodeArgs(entry.value.arguments.toString()),
        ),
    ];
    if (calls.isNotEmpty) finish = LlmFinishReason.toolCalls;

    yield LlmDelta.done(
      LlmResponse(
        parts: parts,
        finishReason: finish,
        usage: usage,
        model: model,
      ),
    );
  }

  LlmResponse _decode(Map<String, dynamic> json) {
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) {
      throw LlmProviderError(
        'The response contained no choices',
        provider: id,
      );
    }
    final choice = choices.first as Map<String, dynamic>;
    final message = (choice['message'] as Map?) ?? const {};

    final parts = <LlmPart>[];
    final content = message['content'];
    if (content is String && content.trim().isNotEmpty) {
      parts.add(TextPart(content));
    }

    final toolCalls = message['tool_calls'];
    if (toolCalls is List) {
      for (var i = 0; i < toolCalls.length; i++) {
        final raw = toolCalls[i];
        if (raw is! Map) continue;
        final fn = raw['function'];
        if (fn is! Map || fn['name'] is! String) continue;
        parts.add(
          ToolCallPart(
            id: raw['id'] as String? ?? 'call-$i',
            name: fn['name'] as String,
            args: _decodeArgs(fn['arguments'] as String? ?? '{}'),
          ),
        );
      }
    }

    var finish = _finishReason(choice['finish_reason'] as String? ?? 'stop');
    if (parts.whereType<ToolCallPart>().isNotEmpty) {
      finish = LlmFinishReason.toolCalls;
    }

    return LlmResponse(
      parts: parts,
      finishReason: finish,
      usage: _usage(json['usage']),
      model: json['model'] as String? ?? model,
    );
  }

  LlmFinishReason _finishReason(String raw) => switch (raw) {
    'tool_calls' || 'function_call' => LlmFinishReason.toolCalls,
    'length' => LlmFinishReason.length,
    'content_filter' => LlmFinishReason.filtered,
    _ => LlmFinishReason.stop,
  };

  LlmUsage _usage(Object? raw) {
    if (raw is! Map) return const LlmUsage();
    return LlmUsage(
      inputTokens: (raw['prompt_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (raw['completion_tokens'] as num?)?.toInt() ?? 0,
    );
  }

  /// Arguments arrive as a JSON *string*, and a truncated or empty one is
  /// common enough that it must not take the whole turn down.
  Map<String, dynamic> _decodeArgs(String raw) {
    if (raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on FormatException {
      return {};
    }
  }
}

class _PartialCall {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}
