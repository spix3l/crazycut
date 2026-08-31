part of 'caption_rasterizer.dart';

class RasterizedCaption {
  const RasterizedCaption({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}
