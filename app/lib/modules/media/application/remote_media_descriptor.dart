part of 'media_url_service.dart';

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
