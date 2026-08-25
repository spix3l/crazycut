/// Capability degradation (AI-9).
///
/// This is the file that makes "provider-agnostic" real rather than aspirational.
/// Features ask for schema-shaped JSON or for tool calls once, against the
/// capable path. Where the configured backend cannot enforce a schema or does
/// not do native tool calling, everything here quietly makes up the difference:
/// the schema goes into the prompt, the JSON is dug out of whatever prose came
/// back, and a non-compliant reply gets exactly one repair round-trip with the
/// validation error fed back.
///
/// Callers get the same parsed object either way and contain no provider
/// branching at all.
library;

import 'dart:convert';

import 'package:crazycut_app/ai/core/llm_message.dart';
import 'package:crazycut_app/ai/core/llm_provider.dart';

/// Requests a JSON value matching [schema] and returns it parsed.
///
/// Throws [LlmSchemaError] only after the repair attempt has also failed, so a
/// single sloppy reply is not surfaced to the user as a failure.
Future<Object?> completeJson(
  LlmProvider provider,
  LlmRequest request, {
  required Map<String, dynamic> schema,
  CancellationToken? cancel,
}) async {
  if (provider.capabilities.jsonSchema) {
    final res = await withRetry(
      () => provider.complete(
        request.copyWith(responseSchema: schema),
        cancel: cancel,
      ),
    );
    _rejectIfDeclined(res, provider);
    // Even a server-enforcing provider can truncate at the token ceiling, which
    // yields valid-looking-but-unterminated JSON.
    return _parseOrThrow(res.text, provider);
  }

  // No server-side enforcement: teach the schema in the prompt instead.
  final guided = request.copyWith(
    messages: [
      ..._withSchemaInstruction(request.messages, schema),
    ],
    clearResponseSchema: true,
  );

  var res = await withRetry(() => provider.complete(guided, cancel: cancel));
  _rejectIfDeclined(res, provider);

  var raw = res.text;
  var candidate = extractJson(raw);
  var problem = candidate == null
      ? 'the reply contained no JSON value'
      : validateAgainstSchema(candidate, schema);

  if (problem == null) return candidate;

  // One repair round-trip, with the actual complaint fed back. Models fix this
  // reliably when told precisely what was wrong; a blind retry usually does not.
  cancel?.throwIfCancelled();
  final repair = guided.copyWith(
    messages: [
      ...guided.messages,
      res.toMessage(),
      LlmMessage.user(
        'That reply could not be used: $problem.\n'
        'Reply again with only the JSON value, matching the schema exactly. '
        'No prose, no code fence, no trailing commentary.',
      ),
    ],
  );

  res = await withRetry(() => provider.complete(repair, cancel: cancel));
  _rejectIfDeclined(res, provider);

  raw = res.text;
  candidate = extractJson(raw);
  problem = candidate == null
      ? 'the reply contained no JSON value'
      : validateAgainstSchema(candidate, schema);

  if (problem != null) {
    throw LlmSchemaError(
      'The model did not return usable JSON: $problem',
      provider: provider.id,
      rawReply: raw,
    );
  }
  return candidate;
}

void _rejectIfDeclined(LlmResponse res, LlmProvider provider) {
  if (res.finishReason == LlmFinishReason.refusal) {
    throw LlmContentFilteredError(
      'The model declined this request.',
      provider: provider.id,
    );
  }
  if (res.finishReason == LlmFinishReason.filtered) {
    throw LlmContentFilteredError(
      'The reply was blocked by the provider\'s safety filter.',
      provider: provider.id,
    );
  }
}

Object? _parseOrThrow(String text, LlmProvider provider) {
  final value = extractJson(text);
  if (value == null) {
    throw LlmSchemaError(
      'The model returned no JSON value.',
      provider: provider.id,
      rawReply: text,
    );
  }
  return value;
}

List<LlmMessage> _withSchemaInstruction(
  List<LlmMessage> messages,
  Map<String, dynamic> schema,
) {
  final instruction = LlmMessage.system(
    'Reply with a single JSON value and nothing else — no prose before or '
    'after, no markdown code fence. It must validate against this JSON Schema:\n'
    '${const JsonEncoder.withIndent('  ').convert(schema)}',
  );
  // System messages go first; some backends only honour a leading system turn.
  final systems = messages.where((m) => m.role == LlmRole.system);
  final rest = messages.where((m) => m.role != LlmRole.system);
  return [...systems, instruction, ...rest];
}

/// Pulls the first complete JSON object or array out of [text], tolerating the
/// prose and code fences that non-enforcing models wrap around it.
///
/// Returns null when there is nothing parseable.
Object? extractJson(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;

  // Fast path: the whole reply is JSON.
  final direct = _tryDecode(trimmed);
  if (direct != null) return direct.value;

  // Strip a fenced block if present and try its contents.
  final fence = RegExp(
    r'```(?:json)?\s*\n([\s\S]*?)```',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (fence != null) {
    final inner = _tryDecode(fence.group(1)!.trim());
    if (inner != null) return inner.value;
  }

  // Otherwise scan for the first balanced { } or [ ] run, respecting strings
  // and escapes so a brace inside a title does not end the scan early.
  for (var i = 0; i < trimmed.length; i++) {
    final ch = trimmed[i];
    if (ch != '{' && ch != '[') continue;
    final end = _matchBalanced(trimmed, i);
    if (end == null) continue;
    final slice = trimmed.substring(i, end + 1);
    final parsed = _tryDecode(slice);
    if (parsed != null) return parsed.value;
  }
  return null;
}

({Object? value})? _tryDecode(String s) {
  try {
    return (value: jsonDecode(s) as Object?);
  } on FormatException {
    return null;
  }
}

int? _matchBalanced(String s, int start) {
  final open = s[start];
  final close = open == '{' ? '}' : ']';
  var depth = 0;
  var inString = false;
  var escaped = false;

  for (var i = start; i < s.length; i++) {
    final ch = s[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == open) {
      depth++;
    } else if (ch == close) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return null;
}

/// Validates [value] against the subset of JSON Schema this layer emits, and
/// returns a human-readable complaint, or null when it fits.
///
/// Deliberately not a full JSON Schema implementation: its job is to catch a
/// non-compliant model reply and describe the problem well enough that the
/// repair round-trip succeeds.
String? validateAgainstSchema(
  Object? value,
  Map<String, dynamic> schema, [
  String path = 'value',
]) {
  final type = schema['type'] as String?;

  if (type != null) {
    final mismatch = switch (type) {
      'object' => value is! Map,
      'array' => value is! List,
      'string' => value is! String,
      'number' => value is! num,
      'integer' => value is! int && !(value is double && value % 1 == 0),
      'boolean' => value is! bool,
      'null' => value != null,
      _ => false,
    };
    if (mismatch) {
      return '$path should be $type but was ${_describe(value)}';
    }
  }

  final enumValues = schema['enum'] as List?;
  if (enumValues != null && !enumValues.contains(value)) {
    return '$path must be one of ${enumValues.join(', ')} but was ${_describe(value)}';
  }

  if (value is Map) {
    final props = schema['properties'] as Map<String, dynamic>?;
    final required = (schema['required'] as List?)?.cast<String>() ?? const [];
    for (final key in required) {
      if (!value.containsKey(key)) return '$path is missing required "$key"';
    }
    if (props != null) {
      for (final entry in value.entries) {
        final sub = props[entry.key] as Map<String, dynamic>?;
        if (sub == null) continue;
        final problem = validateAgainstSchema(
          entry.value,
          sub,
          '$path.${entry.key}',
        );
        if (problem != null) return problem;
      }
    }
  }

  if (value is List) {
    final items = schema['items'] as Map<String, dynamic>?;
    if (items != null) {
      for (var i = 0; i < value.length; i++) {
        final problem = validateAgainstSchema(value[i], items, '$path[$i]');
        if (problem != null) return problem;
      }
    }
  }

  return null;
}

String _describe(Object? value) {
  if (value == null) return 'null';
  if (value is String) return 'a string';
  if (value is num) return 'a number';
  if (value is bool) return 'a boolean';
  if (value is List) return 'an array';
  if (value is Map) return 'an object';
  return value.runtimeType.toString();
}
