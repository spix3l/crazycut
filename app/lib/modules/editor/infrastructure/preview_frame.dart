part of 'preview_renderer.dart';

/// One composited preview frame.
class PreviewFrame {
  const PreviewFrame({
    required this.time,
    required this.width,
    required this.height,
    required this.rgba,
  });

  final Rt time;
  final int width;
  final int height;
  final Uint8List rgba;
}
