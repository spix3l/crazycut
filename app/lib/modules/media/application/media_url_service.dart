import 'dart:async';
import 'package:http/http.dart' as http;

import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/engine/media_worker.dart';

part 'media_url_exception.dart';
part 'remote_media_descriptor.dart';
part 'you_tube_link.dart';

class MediaUrlService {
  MediaUrlService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<RemoteMediaDescriptor> inspect(String value) async {
    final entered = normalizeRemoteUrl(value);
    if (isYouTubeMediaHost(entered)) {
      throw const MediaUrlException(
        'YouTube streams can only be used through the reference player.',
      );
    }
    final uri = Uri.parse(entered);
    http.StreamedResponse response;
    try {
      response = await _client
          .send(http.Request('HEAD', uri))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode == 405 || response.statusCode == 501) {
        await response.stream.drain<void>();
        final request = http.Request('GET', uri)
          ..headers['Range'] = 'bytes=0-0';
        response = await _client
            .send(request)
            .timeout(const Duration(seconds: 12));
      }
    } on TimeoutException {
      throw const MediaUrlException('The server took too long to respond.');
    } on Object catch (error) {
      throw MediaUrlException('Could not reach this URL: $error');
    }
    try {
      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw MediaUrlException(
          'The server returned HTTP ${response.statusCode}.',
        );
      }
      final contentType =
          (response.headers['content-type'] ?? '')
              .split(';')
              .first
              .trim()
              .toLowerCase();
      if (contentType == 'text/html' ||
          contentType == 'application/xhtml+xml') {
        throw const MediaUrlException(
          'This is a web page, not a direct media URL.',
        );
      }
      final resolved = response.request?.url.toString() ?? entered;
      return RemoteMediaDescriptor(
        enteredUrl: entered,
        resolvedUrl: resolved,
        name: _remoteName(response.headers, Uri.parse(resolved)),
        contentType: contentType,
        etag: response.headers['etag'],
        lastModified: response.headers['last-modified'],
        contentLength: int.tryParse(response.headers['content-length'] ?? ''),
      );
    } finally {
      await response.stream.drain<void>();
    }
  }

  Future<ProbeResult> probe(RemoteMediaDescriptor descriptor) async {
    final probe = await MediaWorker.instance.probe(descriptor.enteredUrl);
    if (probe == null || probe.type == 'unknown') {
      throw const MediaUrlException(
        'The URL did not resolve to supported audio, video, or image media.',
      );
    }
    return probe;
  }

  Future<List<int>> downloadBytes(String url, {int maxBytes = 10 << 20}) async {
    final response = await _client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MediaUrlException(
        'The server returned HTTP ${response.statusCode}.',
      );
    }
    if (response.bodyBytes.length > maxBytes) {
      throw MediaUrlException(
        'The remote file exceeds the ${maxBytes >> 20} MB limit.',
      );
    }
    return response.bodyBytes;
  }

  void close() => _client.close();
}

String _remoteName(Map<String, String> headers, Uri uri) {
  final disposition = headers['content-disposition'] ?? '';
  final match = RegExp(
    r'''filename\*?=(?:UTF-8''|["'])?([^"';]+)''',
    caseSensitive: false,
  ).firstMatch(disposition);
  if (match != null) {
    return Uri.decodeComponent(match.group(1)!.trim());
  }
  if (uri.pathSegments.isNotEmpty && uri.pathSegments.last.isNotEmpty) {
    return Uri.decodeComponent(uri.pathSegments.last);
  }
  return uri.host;
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
