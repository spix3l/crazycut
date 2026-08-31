part of 'engine.dart';

class RawFrame {
  RawFrame(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;
}
