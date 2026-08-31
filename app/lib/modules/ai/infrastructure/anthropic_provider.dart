/// Anthropic Messages adapter (AI-10).
///
/// Earns its own adapter because the wire shape genuinely differs from the
/// chat-completions family: the system prompt is a top-level field rather than a
/// message, and tool calls and results are content blocks inside ordinary turns
/// rather than a parallel `tool_calls` array.
library;

import 'dart:convert';

import 'package:crazycut_app/modules/ai/domain/llm_message.dart';
import 'package:crazycut_app/modules/ai/domain/llm_provider.dart';
import 'package:crazycut_app/modules/ai/infrastructure/http_provider.dart';

class AnthropicProvider extends HttpLlmProvider {
  AnthropicProvider({
    required this.model,
    required this.apiKey,
    super.baseUrl = 'https://api.anthropic.com/v1',
    this.apiVersion = '2023-06-01',
    LlmCapabilities? capabilities,
    super.client,
  }) : _capabilities = capabilities ?? defaultCapabilities;

  static const defaultCapabilities = LlmCapabilities(
    tools: true,
    jsonSchema: false,
    streaming: true,
    contextWindow: 200000,
  );

  @override
  final String model;
  final String apiKey;
  final String apiVersion;
  final LlmCapabilities _capabilities;

  @override
  String get id => 'anthropic';

  @override
  String get displayName => 'Anthropic';

  @override
  LlmCapabilities get capabilities => _capabilities;

  @override
  Map<String, String> headers() => {
    'x-api-key': apiKey,
    'anthropic-version': apiVersion,
  };

  Map<String, dynamic> _body(LlmRequest request, {required bool stream}) {
    final systems = request.messages
        .where((m) => m.role == LlmRole.system)
        .map((m) => m.text)
        .where((t) => t.isNotEmpty)
        .toList();

    final body = <String, dynamic>{
      'model': model,
      'max_tokens': request.maxTokens,
      'messages': _encodeMessages(
        request.messages.where((m) => m.role != LlmRole.system).toList(),
      ),
      if (systems.isNotEmpty) 'system': systems.join('\n\n'),
      if (stream) 'stream': true,
    };

    if (request.tools.isNotEmpty) {
      body['tools'] = [
        for (final t in request.tools)
          {
            'name': t.name,
            'description': t.description,
            'input_schema': t.schema,
          },
      ];
    }

    // Extended thinking is only requested when the caller actually wants depth.
    // Current models take `adaptive` and reject a token budget outright, and
    // older ones reject `adaptive` — so this is deliberately the one shape we
    // send, and only when asked for.
    if (request.reasoning == LlmReasoning.deep) {
      body['thinking'] = {'type': 'adaptive'};
    }

    // Sampling parameters are rejected by several current models, so they are
    // sent only when a caller explicitly set one.
    if (request.temperature != null) {
      body['temperature'] = request.temperature;
    }
    return body;
  }

  List<Map<String, dynamic>> _encodeMessages(List<LlmMessage> messages) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final blocks = <Map<String, dynamic>>[];
      for (final part in m.parts) {
        switch (part) {
          case TextPart(:final text) when text.trim().isNotEmpty:
            blocks.add({'type': 'text', 'text': text});
          case TextPart():
            break;
          case ToolCallPart(:final id, :final name, :final args):
            blocks.add({
              'type': 'tool_use',
              'id': id,
              'name': name,
              'input': args,
            });
          case ToolResultPart(:final callId, :final content, :final isError):
            blocks.add({
              'type': 'tool_result',
              'tool_use_id': callId,
              'content': content,
              if (isError) 'is_error': true,
            });
        }
      }
      if (blocks.isEmpty) continue;
      out.add({
        'role': m.role == LlmRole.assistant ? 'assistant' : 'user',
        'content': blocks,
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
      '/messages',
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
    final calls = <int, _PartialBlock>{};
    var finish = LlmFinishReason.stop;
    var usage = const LlmUsage();

    await for (final frame in postSse(
      '/messages',
      _body(request, stream: true),
      cancel: cancel,
    )) {
      switch (frame['type']) {
        case 'message_start':
          final message = frame['message'];
          if (message is Map) usage = _usage(message['usage']);

        case 'content_block_start':
          final index = (frame['index'] as num?)?.toInt() ?? 0;
          final block = frame['content_block'];
          if (block is Map && block['type'] == 'tool_use') {
            calls[index] = _PartialBlock(
              id: block['id'] as String? ?? 'call-$index',
              name: block['name'] as String? ?? '',
            );
          }

        case 'content_block_delta':
          final index = (frame['index'] as num?)?.toInt() ?? 0;
          final delta = frame['delta'];
          if (delta is! Map) break;
          if (delta['type'] == 'text_delta' && delta['text'] is String) {
            final text = delta['text'] as String;
            buffer.write(text);
            yield LlmDelta.text(text);
          } else if (delta['type'] == 'input_json_delta' &&
              delta['partial_json'] is String) {
            calls[index]?.json.write(delta['partial_json'] as String);
          }

        case 'message_delta':
          final delta = frame['delta'];
          if (delta is Map && delta['stop_reason'] is String) {
            finish = _finishReason(delta['stop_reason'] as String);
          }
          final u = frame['usage'];
          if (u is Map) {
            usage = usage +
                LlmUsage(
                  outputTokens: (u['output_tokens'] as num?)?.toInt() ?? 0,
                );
          }
      }
    }

    final parts = <LlmPart>[
      if (buffer.isNotEmpty) TextPart(buffer.toString()),
      for (final entry in calls.entries)
        ToolCallPart(
          id: entry.value.id,
          name: entry.value.name,
          args: _decodeArgs(entry.value.json.toString()),
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
    final content = json['content'];
    final parts = <LlmPart>[];

    if (content is List) {
      for (var i = 0; i < content.length; i++) {
        final block = content[i];
        if (block is! Map) continue;
        switch (block['type']) {
          case 'text':
            final text = block['text'];
            if (text is String && text.trim().isNotEmpty) {
              parts.add(TextPart(text));
            }
          case 'tool_use':
            parts.add(
              ToolCallPart(
                id: block['id'] as String? ?? 'call-$i',
                name: block['name'] as String? ?? '',
                args: block['input'] is Map
                    ? Map<String, dynamic>.from(block['input'] as Map)
                    : const {},
              ),
            );
        }
      }
    }

    var finish = _finishReason(json['stop_reason'] as String? ?? 'end_turn');
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
    'tool_use' => LlmFinishReason.toolCalls,
    'max_tokens' => LlmFinishReason.length,
    'refusal' => LlmFinishReason.refusal,
    _ => LlmFinishReason.stop,
  };

  LlmUsage _usage(Object? raw) {
    if (raw is! Map) return const LlmUsage();
    return LlmUsage(
      inputTokens: (raw['input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (raw['output_tokens'] as num?)?.toInt() ?? 0,
    );
  }

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

class _PartialBlock {
  _PartialBlock({required this.id, required this.name});
  final String id;
  final String name;
  final StringBuffer json = StringBuffer();
}
