import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Decodes a raw RGBA8 buffer into a [ui.Image] asynchronously and paints it
/// with `BoxFit.contain`. Re-decodes only when the pixel payload changes
/// (identity), so scrubbing at one resolution reuses a stable decode path.
///
/// The previous image stays on screen until the next one is ready, so a fast
/// sequence of frames never flashes an empty monitor.
class RgbaFrame extends StatefulWidget {
  const RgbaFrame({
    super.key,
    required this.bytes,
    required this.width,
    required this.height,
    this.filterQuality = FilterQuality.medium,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final FilterQuality filterQuality;

  @override
  State<RgbaFrame> createState() => _RgbaFrameState();
}

class _RgbaFrameState extends State<RgbaFrame> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    unawaited(_decode());
  }

  @override
  void didUpdateWidget(RgbaFrame old) {
    super.didUpdateWidget(old);
    // _decode is async: kicking it off inside setState would hand setState a
    // Future. It calls setState itself once the image exists.
    if (!identical(old.bytes, widget.bytes)) unawaited(_decode());
  }

  /// A decode is outstanding. During playback frames arrive faster than the
  /// engine can turn them into textures; starting a second decode before the
  /// first finishes only queues uploads that are already stale by the time
  /// they land. Coalescing to "newest wins" keeps the monitor on the freshest
  /// frame instead of walking through a backlog.
  bool _decoding = false;

  Future<void> _decode() async {
    if (_decoding) return;
    _decoding = true;
    try {
      while (mounted) {
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
        if (!mounted) {
          image.dispose();
          return;
        }
        // A newer frame arrived while decoding: show this one anyway (it is
        // still newer than what is on screen) and loop to catch up.
        final old = _image;
        setState(() => _image = image);
        old?.dispose();
        if (identical(bytes, widget.bytes)) return;
      }
    } finally {
      _decoding = false;
    }
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
      // The frame is rendered at (roughly) display resolution, so the residual
      // scale is small. The monitor drops to a cheaper sampler while the
      // transport is moving.
      filterQuality: widget.filterQuality,
    );
  }
}
