/// Local model adapter (AI-10).
///
/// Talks to an Ollama server on the user's own machine. No key, no account,
/// nothing leaving the box — this is the adapter that lets AI assist honour the
/// "Yours" pillar (`00-product-overview.md` §6) in full rather than as a
/// caveat. Capability-wise it is the weakest of the three, which makes it the
/// adapter that exercises the core's degradation paths (AI-9) in real use.
library;

import 'dart:convert';

import 'package:crazycut_app/modules/ai/domain/llm_message.dart';
import 'package:crazycut_app/modules/ai/domain/llm_provider.dart';
import 'package:crazycut_app/modules/ai/infrastructure/http_provider.dart';

class OllamaProvider extends HttpLlmProvider {
  OllamaProvider({
    required this.model,
    super.baseUrl = 'http://127.0.0.1:11434',
    LlmCapabilities? capabilities,
    super.client,
  }) : _capabilities = capabilities ?? defaultCapabilities;

  /// Conservative on purpose. Ollama forwards tool calls only for models that
  /// were trained for them, and its `format` field constrains JSON shape far
  /// less strictly than a server-enforced schema. Claiming less here means the
  /// core's fallbacks engage and the feature works; claiming more would turn a
  /// graceful degradation into a runtime failure (AI-8).
  static const defaultCapabilities = LlmCapabilities(
    tools: false,
    jsonSchema: false,
    streaming: true,
    contextWindow: 32768,
  );

  @override
  final String model;
  final LlmCapabilities _capabilities;

  @override
  String get id => 'ollama';

  @override
  String get displayName => 'Ollama (local)';

  @override
  LlmCapabilities get capabilities => _capabilities;

  @override
  Map<String, String> headers() => const {};

  Map<String, dynamic> _body(LlmRequest request, {required bool stream}) {
    return <String, dynamic>{
      'model': model,
      'messages': _encodeMessages(request.messages),
      'stream': stream,
      'options': <String, dynamic>{
        'num_predict': request.maxTokens,
        if (request.temperature != null) 'temperature': request.temperature,
      },
      // Ollama's `format: json` is a loose nudge rather than schema
      // enforcement, so we set it as a hint and still let the core validate.
      if (request.responseSchema != null) 'format': 'json',
      if (request.tools.isNotEmpty && _capabilities.tools)
        'tools': [
          for (final t in request.tools)
            {
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': t.schema,
              },
            },
        ],
    };
  }

  List<Map<String, dynamic>> _encodeMessages(List<LlmMessage> messages) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final results = m.parts.whereType<ToolResultPart>().toList();
      if (results.isNotEmpty) {
        for (final r in results) {
          out.add({
            'role': 'tool',
            'content': r.isError ? 'ERROR: ${r.content}' : r.content,
          });
        }
        continue;
      }

      final calls = m.parts.whereType<ToolCallPart>().toList();
      out.add({
        'role': switch (m.role) {
          LlmRole.system => 'system',
          LlmRole.user => 'user',
          LlmRole.assistant => 'assistant',
        },
        'content': m.text,
        if (calls.isNotEmpty)
          'tool_calls': [
            for (final c in calls)
              {
                'function': {'name': c.name, 'arguments': c.args},
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
      '/api/chat',
      _body(request, stream: false),
      cancel: cancel,
    );
    return _decode(json);
  }

  /// Ollama streams newline-delimited JSON rather than SSE, so this reads the
  /// body directly instead of going through [postSse].
  @override
  Stream<LlmDelta> stream(
    LlmRequest request, {
    CancellationToken? cancel,
  }) async* {
    final buffer = StringBuffer();
    var usage = const LlmUsage();
    final calls = <ToolCallPart>[];

    await for (final frame in postNdjson(
      '/api/chat',
      _body(request, stream: true),
      cancel: cancel,
    )) {
      final message = frame['message'];
      if (message is Map) {
        final content = message['content'];
        if (content is String && content.isNotEmpty) {
          buffer.write(content);
          yield LlmDelta.text(content);
        }
        calls.addAll(_toolCalls(message));
      }
      if (frame['done'] == true) usage = _usage(frame);
    }

    yield LlmDelta.done(
      LlmResponse(
        parts: [
          if (buffer.isNotEmpty) TextPart(buffer.toString()),
          ...calls,
        ],
        finishReason: calls.isEmpty
            ? LlmFinishReason.stop
            : LlmFinishReason.toolCalls,
        usage: usage,
        model: model,
      ),
    );
  }

  LlmResponse _decode(Map<String, dynamic> json) {
    final message = json['message'];
    final parts = <LlmPart>[];

    if (message is Map) {
      final content = message['content'];
      if (content is String && content.trim().isNotEmpty) {
        parts.add(TextPart(content));
      }
      parts.addAll(_toolCalls(message));
    }

    final hasCalls = parts.whereType<ToolCallPart>().isNotEmpty;
    return LlmResponse(
      parts: parts,
      finishReason: hasCalls
          ? LlmFinishReason.toolCalls
          : json['done_reason'] == 'length'
          ? LlmFinishReason.length
          : LlmFinishReason.stop,
      usage: _usage(json),
      model: json['model'] as String? ?? model,
    );
  }

  Iterable<ToolCallPart> _toolCalls(Map<dynamic, dynamic> message) sync* {
    final raw = message['tool_calls'];
    if (raw is! List) return;
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is! Map) continue;
      final fn = entry['function'];
      if (fn is! Map || fn['name'] is! String) continue;
      final args = fn['arguments'];
      yield ToolCallPart(
        id: 'ollama-call-$i',
        name: fn['name'] as String,
        args: switch (args) {
          final Map m => Map<String, dynamic>.from(m),
          final String s => _decodeArgs(s),
          _ => const {},
        },
      );
    }
  }

  Map<String, dynamic> _decodeArgs(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on FormatException {
      return {};
    }
  }

  LlmUsage _usage(Map<String, dynamic> json) => LlmUsage(
    inputTokens: (json['prompt_eval_count'] as num?)?.toInt() ?? 0,
    outputTokens: (json['eval_count'] as num?)?.toInt() ?? 0,
  );
}
