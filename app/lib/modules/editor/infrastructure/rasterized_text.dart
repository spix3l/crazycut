part of 'text_rasterizer.dart';

class RasterizedText {
  const RasterizedText({
    required this.bytes,
    required this.width,
    required this.height,
  });
  final Uint8List bytes;
  final int width;
  final int height;
}
