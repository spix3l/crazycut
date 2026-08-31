part of 'poster_worker.dart';

/// One composited frame, rendered off the UI isolate for a project poster.
class PosterFrame {
  const PosterFrame({required this.width, required this.height, required this.rgba});
  final int width;
  final int height;
  final Uint8List rgba;
}
