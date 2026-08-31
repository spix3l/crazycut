part of 'media_url_service.dart';

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
