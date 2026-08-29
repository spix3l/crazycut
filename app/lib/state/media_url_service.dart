import 'dart:async';
import 'package:http/http.dart' as http;

import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/engine/media_worker.dart';

class MediaUrlException implements Exception {
  const MediaUrlException(this.message);
  final String message;

  @override
  String toString() => message;
}

class RemoteMediaDescriptor {
  const RemoteMediaDescriptor({
    required this.enteredUrl,
    required this.resolvedUrl,
    required this.name,
    required this.contentType,
    this.etag,
    this.lastModified,
    this.contentLength,
  });

  final String enteredUrl;
  final String resolvedUrl;
  final String name;
  final String contentType;
  final String? etag;
  final String? lastModified;
  final int? contentLength;

  String get revision => [
    etag ?? '',
    lastModified ?? '',
    contentLength?.toString() ?? '',
  ].join('|');
}

class YouTubeLink {
  const YouTubeLink(this.videoId, this.startSeconds);
  final String videoId;
  final int startSeconds;
}

String normalizeRemoteUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
    throw const MediaUrlException('Enter a complete HTTP or HTTPS URL.');
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    throw const MediaUrlException('Only HTTP and HTTPS URLs are supported.');
  }
  if (uri.userInfo.isNotEmpty) {
    throw const MediaUrlException(
      'URLs containing a username or password are not supported.',
    );
  }
  final port =
      (scheme == 'http' && uri.port == 80) ||
              (scheme == 'https' && uri.port == 443)
          ? null
          : uri.hasPort
          ? uri.port
          : null;
  final normalized =
      uri
          .replace(
            scheme: scheme,
            host: uri.host.toLowerCase(),
            port: port,
            fragment: '',
          )
          .toString();
  return normalized.endsWith('#')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
}

YouTubeLink? parseYouTubeLink(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return null;
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  String? id;
  if (host == 'youtu.be') {
    id = uri.pathSegments.firstOrNull;
  } else if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
    if (uri.path == '/watch') id = uri.queryParameters['v'];
    if (uri.pathSegments.length >= 2 &&
        const {'embed', 'shorts', 'live'}.contains(uri.pathSegments.first)) {
      id = uri.pathSegments[1];
    }
  }
  if (id == null || !RegExp(r'^[A-Za-z0-9_-]{6,20}$').hasMatch(id)) {
    return null;
  }
  final start = _youtubeSeconds(
    uri.queryParameters['t'] ?? uri.queryParameters['start'],
  );
  return YouTubeLink(id, start);
}

int _youtubeSeconds(String? value) {
  if (value == null || value.isEmpty) return 0;
  final numeric = int.tryParse(value.replaceAll('s', ''));
  if (numeric != null) return numeric.clamp(0, 1 << 31);
  final match = RegExp(r'(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?').firstMatch(value);
  if (match == null) return 0;
  return (int.tryParse(match.group(1) ?? '') ?? 0) * 3600 +
      (int.tryParse(match.group(2) ?? '') ?? 0) * 60 +
      (int.tryParse(match.group(3) ?? '') ?? 0);
}

bool isYouTubeMediaHost(String value) {
  final host = Uri.tryParse(value)?.host.toLowerCase() ?? '';
  return host == 'googlevideo.com' || host.endsWith('.googlevideo.com');
}

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
