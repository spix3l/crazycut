part of 'svg_rasterizer.dart';

class SvgRaster {
  const SvgRaster({
    required this.path,
    required this.width,
    required this.height,
    required this.png,
  });

  final String path;
  final int width;
  final int height;
  final Uint8List png;
}
