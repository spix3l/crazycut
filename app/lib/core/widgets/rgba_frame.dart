import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
/// Decodes a raw RGBA8 buffer into a [ui.Image] asynchronously and paints it
/// with `BoxFit.contain`. Re-decodes only when the pixel payload changes
/// (identity), so scrubbing at one resolution reuses a stable decode path.
class RgbaFrame extends StatefulWidget {
  const RgbaFrame({
    super.key,
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;

  @override
  State<RgbaFrame> createState() => _RgbaFrameState();
}

class _RgbaFrameState extends State<RgbaFrame> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(RgbaFrame old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes)) {
      setState(() => _decode());
    }
  }

  Future<void> _decode() async {
    final bytes = widget.bytes;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      widget.width,
      widget.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    if (!mounted || !identical(bytes, widget.bytes)) return;
    final old = _image;
    setState(() => _image = image);
    old?.dispose();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox.expand();
    return RawImage(
      image: image,
      fit: BoxFit.contain,
    );
  }
}
