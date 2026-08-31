/// Shared HTTP plumbing for the wire adapters.
///
/// Holds exactly the parts that are genuinely identical between providers —
/// issuing a JSON request, honouring cancellation, and mapping transport and
/// status failures onto the one error taxonomy (AI-7). Everything
/// vendor-shaped stays in the adapter that owns it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:crazycut_app/modules/ai/domain/llm_provider.dart';

abstract class HttpLlmProvider extends LlmProvider {
  HttpLlmProvider({required this.baseUrl, http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final String baseUrl;
  final http.Client _client;
  final bool _ownsClient;

  http.Client get client => _client;

  Uri endpoint(String path) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base$path');
  }

  Map<String, String> headers();

  /// POSTs [body] and returns the decoded JSON object.
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    final request = http.Request('POST', endpoint(path))
      ..headers.addAll({'content-type': 'application/json', ...headers()})
      ..body = jsonEncode(body);

    http.StreamedResponse streamed;
    try {
      final future = _client.send(request);
      cancel?.onCancel(() => _client.close());
      streamed = await future;
    } on Object catch (e) {
      if (cancel?.isCancelled ?? false) throw LlmCancelledError(provider: id);
      throw LlmTransportError(
        'Could not reach $baseUrl',
        provider: id,
        cause: e,
      );
    }

    final text = await streamed.stream.bytesToString();
    cancel?.throwIfCancelled();

    if (streamed.statusCode >= 400) {
      throw mapStatus(streamed.statusCode, text, streamed.headers);
    }

    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw LlmProviderError(
          'Expected a JSON object from $baseUrl$path',
          provider: id,
          statusCode: streamed.statusCode,
        );
      }
      return decoded;
    } on FormatException {
      throw LlmProviderError(
        'The response from $baseUrl$path was not JSON',
        provider: id,
        statusCode: streamed.statusCode,
      );
    }
  }

  /// POSTs [body] and yields decoded server-sent-event payloads.
  Stream<Map<String, dynamic>> postSse(
    String path,
    Map<String, dynamic> body, {
    CancellationToken? cancel,
  }) async* {
    cancel?.throwIfCancelled();
    final request = http.Request('POST', endpoint(path))
      ..headers.addAll({
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        ...headers(),
      })
      ..body = jsonEncode(body);

    http.StreamedResponse streamed;
    try {
      final future = _client.send(request);
      cancel?.onCancel(() => _client.close());
      streamed = await future;
    } on Object catch (e) {
      if (cancel?.isCancelled ?? false) throw LlmCancelledError(provider: id);
      throw LlmTransportError(
        'Could not reach $baseUrl',
        provider: id,
        cause: e,
      );
    }

    if (streamed.statusCode >= 400) {
      final text = await streamed.stream.bytesToString();
      throw mapStatus(streamed.statusCode, text, streamed.headers);
    }

    final lines = streamed.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      cancel?.throwIfCancelled();
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) yield decoded;
      } on FormatException {
        // A malformed frame mid-stream is not worth failing the whole
        // generation over; the terminal event still carries the totals.
        continue;
      }
    }
  }

  /// POSTs [body] and yields decoded newline-delimited JSON frames.
  ///
  /// Not every provider streams as SSE — Ollama, and several local servers,
  /// emit one JSON object per line instead.
  Stream<Map<String, dynamic>> postNdjson(
    String path,
    Map<String, dynamic> body, {
    CancellationToken? cancel,
  }) async* {
    cancel?.throwIfCancelled();
    final request = http.Request('POST', endpoint(path))
      ..headers.addAll({'content-type': 'application/json', ...headers()})
      ..body = jsonEncode(body);

    http.StreamedResponse streamed;
    try {
      final future = _client.send(request);
      cancel?.onCancel(() => _client.close());
      streamed = await future;
    } on Object catch (e) {
      if (cancel?.isCancelled ?? false) throw LlmCancelledError(provider: id);
      throw LlmTransportError(
        'Could not reach $baseUrl',
        provider: id,
        cause: e,
      );
    }

    if (streamed.statusCode >= 400) {
      final text = await streamed.stream.bytesToString();
      throw mapStatus(streamed.statusCode, text, streamed.headers);
    }

    final lines = streamed.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      cancel?.throwIfCancelled();
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) yield decoded;
      } on FormatException {
        continue;
      }
    }
  }

  /// Maps an HTTP failure onto the shared taxonomy. Adapters override to read
  /// their provider's error body, then defer here for the status handling.
  LlmError mapStatus(int status, String body, Map<String, String> headers) {
    final detail = extractErrorMessage(body) ?? _truncate(body);
    switch (status) {
      case 401:
      case 403:
        return LlmAuthError(
          'The endpoint rejected the credentials: $detail',
          provider: id,
        );
      case 404:
        return LlmProviderError(
          'Not found. Check the base URL and model name: $detail',
          provider: id,
          statusCode: status,
        );
      case 413:
        return LlmContextOverflowError(
          'The request was too large: $detail',
          provider: id,
        );
      case 429:
        return LlmRateLimitError(
          'Rate limited: $detail',
          provider: id,
          retryAfterValue: _retryAfter(headers),
        );
      default:
        if (status >= 500) {
          return LlmProviderError(
            'The provider reported a server error ($status): $detail',
            provider: id,
            statusCode: status,
            isServerFault: true,
          );
        }
        // 400s are usually a context overflow or a bad parameter; the body is
        // the only way to tell, and every provider words it differently.
        final lower = detail.toLowerCase();
        if (lower.contains('context') &&
            (lower.contains('length') ||
                lower.contains('window') ||
                lower.contains('too long'))) {
          return LlmContextOverflowError(detail, provider: id);
        }
        return LlmProviderError(
          detail,
          provider: id,
          statusCode: status,
        );
    }
  }

  /// Digs the human-readable message out of the many shapes providers use.
  String? extractErrorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final error = decoded['error'];
      if (error is String) return error;
      if (error is Map && error['message'] is String) {
        return error['message'] as String;
      }
      if (decoded['message'] is String) return decoded['message'] as String;
      if (decoded['detail'] is String) return decoded['detail'] as String;
    } on FormatException {
      return null;
    }
    return null;
  }

  Duration? _retryAfter(Map<String, String> headers) {
    final raw = headers['retry-after'];
    if (raw == null) return null;
    final seconds = int.tryParse(raw.trim());
    return seconds == null ? null : Duration(seconds: seconds);
  }

  String _truncate(String s) =>
      s.length <= 300 ? s.trim() : '${s.substring(0, 300).trim()}…';

  @override
  void dispose() {
    if (_ownsClient) _client.close();
  }
}
