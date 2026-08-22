import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'package:crazycut_app/data/text_content.dart';

/// Rasterizes a [TextContent] into an RGBA8 buffer the engine composites as a
/// texture (TXT-7). Runs through Flutter's text stack so typography matches
/// the on-canvas editor exactly; emoji ride the same path. Sizes are
/// normalized to sequence height (fontSize is px @1080), rendered at 2× and
/// downscaled by the sampler for crisp preview.
class TextRasterizer {
  TextRasterizer._();
  static final TextRasterizer instance = TextRasterizer._();

  /// Rasters keyed by style+content. Preview re-renders the same text on every
  /// frame, and rasterizing through the text stack each time was one of the
  /// costs that kept playback from running in real time.
  static const int _cacheLimit = 32;
  final Map<String, RasterizedText> _cache = {};

  Future<RasterizedText?> render(
    TextContent text, {
    required int canvasWidth,
    required int sequenceHeight,
  }) async {
    final content = text.content;
    if (content.isEmpty) return null;

    final key = jsonEncode({
      'text': text.toJson(),
      'w': canvasWidth,
      'h': sequenceHeight,
    });
    final cached = _cache[key];
    if (cached != null) {
      // Refresh recency.
      _cache.remove(key);
      _cache[key] = cached;
      return cached;
    }

    final scale = sequenceHeight <= 0 ? 1.0 : sequenceHeight / 1080.0;
    const supersample = 2.0;
    final fontSize =
        (text.fontSize * scale * supersample).clamp(8.0, 512.0).toDouble();
    final fontWeight = _weight(text.fontWeight);
    final fontFamily = text.fontFamily == 'default' ? null : text.fontFamily;
    final lineHeight = text.lineHeight <= 0 ? 1.2 : text.lineHeight;

    final tp = TextPainter(
      text: TextSpan(
        text: content,
        style: TextStyle(
          color: _color(text.color),
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: fontWeight,
          height: lineHeight,
          letterSpacing: text.letterSpacing * scale * supersample,
        ),
      ),
      textAlign: _align(text.align),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: canvasWidth.toDouble());

    final backgroundPad = text.backgroundPadding * scale * supersample;
    final strokePad = text.strokeWidth * scale * supersample;
    final pad = math.max(
      fontSize * 0.25,
      math.max(backgroundPad, strokePad),
    ).ceil();
    final width = (tp.width.ceil() + pad * 2).clamp(4, canvasWidth);
    final height = (tp.height.ceil() + pad * 2).clamp(4, 4096);

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // Background box (TXT-3).
    final bgColor = _color(text.backgroundColor);
    if (bgColor.a > 0) {
      final r = text.backgroundRadius * scale * supersample;
      final rect = Rect.fromLTWH(
        pad - backgroundPad,
        pad - backgroundPad,
        math.min(tp.width + backgroundPad * 2, width.toDouble()),
        math.min(tp.height + backgroundPad * 2, height.toDouble()),
      );
      final paint = Paint()..color = bgColor;
      if (r > 0) {
        canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)), paint);
      } else {
        canvas.drawRect(rect, paint);
      }
    }

    // Drop shadow: a second offset, blurred paint behind the fill.
    if (text.shadowOpacity > 0) {
      final sc = _color(text.shadowColor);
      final shadowTp = TextPainter(
        text: TextSpan(
          text: content,
          style: TextStyle(
            color: sc.withValues(alpha: text.shadowOpacity),
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: fontWeight,
            height: lineHeight,
            letterSpacing: text.letterSpacing * scale * supersample,
          ),
        ),
        textAlign: _align(text.align),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: canvasWidth.toDouble());
      if (text.shadowBlur > 0) {
        canvas.saveLayer(
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          Paint(),
        );
      }
      shadowTp.paint(
        canvas,
        Offset(pad + text.shadowOffsetX * scale * supersample,
            pad + text.shadowOffsetY * scale * supersample),
      );
      if (text.shadowBlur > 0) {
        // Blur approximated by painting the shadow twice with slight offsets
        // (real blur arrives with the GPU path in M3).
        shadowTp.paint(
          canvas,
          Offset(pad + (text.shadowOffsetX + 1.5) * scale * supersample,
              pad + (text.shadowOffsetY + 1.5) * scale * supersample),
        );
        canvas.restore();
      }
    }

    // Stroke sits behind the fill so the inspector's outline controls affect
    // the actual preview instead of only being persisted in the project file.
    if (text.strokeWidth > 0) {
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = text.strokeWidth * scale * supersample
        ..strokeJoin = StrokeJoin.round
        ..color = _color(text.strokeColor);
      final strokeTp = TextPainter(
        text: TextSpan(
          text: content,
          style: TextStyle(
            foreground: stroke,
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: fontWeight,
            height: lineHeight,
            letterSpacing: text.letterSpacing * scale * supersample,
          ),
        ),
        textAlign: _align(text.align),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: canvasWidth.toDouble());
      strokeTp.paint(canvas, Offset(pad.toDouble(), pad.toDouble()));
    }

    // Fill.
    tp.paint(canvas, Offset(pad.toDouble(), pad.toDouble()));
    final picture = recorder.endRecording();

    final image = picture.toImageSync(width, height);
    final byteData =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    image.dispose();
    picture.dispose();
    if (byteData == null) return null;
    final raster = RasterizedText(
      bytes: byteData.buffer.asUint8List(),
      width: width,
      height: height,
    );
    _cache[key] = raster;
    if (_cache.length > _cacheLimit) _cache.remove(_cache.keys.first);
    return raster;
  }

  /// Drops cached rasters (used when the sequence format changes).
  void clearCache() => _cache.clear();

  FontWeight _weight(String w) => switch (w) {
        'w400' => FontWeight.w400,
        'w500' => FontWeight.w500,
        'w600' => FontWeight.w600,
        'w700' => FontWeight.w700,
        'w800' => FontWeight.w800,
        _ => FontWeight.w600,
      };

  TextAlign _align(String a) => switch (a) {
        'left' => TextAlign.left,
        'right' => TextAlign.right,
        _ => TextAlign.center,
      };

  Color _color(String hex) {
    var s = hex.replaceFirst('#', '');
    if (s.length == 6) s = 'FF$s';
    final value = int.tryParse(s, radix: 16);
    return Color(value ?? 0xFFFFFFFF);
  }
}

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
