part of 'media_url_service.dart';

class MediaUrlException implements Exception {
  const MediaUrlException(this.message);
  final String message;

  @override
  String toString() => message;
}
