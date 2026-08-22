import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:google_fonts/google_fonts.dart';

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

  /// Families whose async install has already been awaited, so the await below
  /// happens once per font instead of once per preview frame.
  final Set<String> _fontsReady = {};

  Future<RasterizedText?> render(
    TextContent text, {
    required int canvasWidth,
    required int sequenceHeight,
    double? localSeconds,
  }) async {
    final content = _visibleContent(text, localSeconds);
    if (content.isEmpty) return null;
    final fontWeight = _weight(text.fontWeight);

    // google_fonts installs a family asynchronously the first time it is used.
    // TextPainter does not wait for that side effect, and caching its fallback
    // raster made a font selection look permanently broken. Await the install
    // once per family: every later frame then reaches the cache without an
    // event-loop turn, which is what kept the raster off the playback path.
    final fontKey = '${text.fontFamily}/${fontWeight.value}';
    if (text.fontFamily != 'default' && !_fontsReady.contains(fontKey)) {
      _googleFont(text.fontFamily, fontWeight);
      try {
        await GoogleFonts.pendingFonts();
      } on Object {
        // System/custom families and offline use still get Flutter's normal
        // font fallback instead of making the whole preview frame fail.
      }
      _fontsReady.add(fontKey);
    }

    final key = jsonEncode({
      'text': text.toJson(),
      'visible': content,
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
    final fontSize = (text.fontSize * scale).clamp(4.0, 512.0).toDouble();
    final lineHeight = text.lineHeight <= 0 ? 1.2 : text.lineHeight;
    final backgroundPad = text.backgroundPadding * scale;
    final strokePad = text.strokeWidth * scale;
    final shadowBlur = text.shadowBlur * scale;
    final shadowX = text.shadowOffsetX * scale;
    final shadowY = text.shadowOffsetY * scale;
    final pad =
        math
            .max(
              2.0,
              math.max(
                backgroundPad,
                math.max(
                  strokePad * 1.5,
                  text.shadowOpacity > 0
                      ? shadowBlur + math.max(shadowX.abs(), shadowY.abs())
                      : 0,
                ),
              ),
            )
            .ceil() +
        2;
    final layoutWidth = math.max(4.0, canvasWidth.toDouble() - pad * 2);
    final shadows =
        text.shadowOpacity > 0
            ? <Shadow>[
              Shadow(
                color: _color(
                  text.shadowColor,
                ).withValues(alpha: text.shadowOpacity.clamp(0.0, 1.0)),
                blurRadius: shadowBlur,
                offset: Offset(shadowX, shadowY),
              ),
            ]
            : null;

    final tp = TextPainter(
      text: TextSpan(
        text: content,
        style: _fontStyle(
          text,
          color: _color(text.color),
          fontSize: fontSize,
          fontWeight: fontWeight,
          height: lineHeight,
          letterSpacing: text.letterSpacing * scale,
          shadows: shadows,
        ),
      ),
      textAlign: _align(text.align),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: layoutWidth);

    final width = (tp.width.ceil() + pad * 2).clamp(4, canvasWidth);
    final height = (tp.height.ceil() + pad * 2).clamp(4, 4096);

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // Background box (TXT-3).
    final bgColor = _color(text.backgroundColor);
    if (bgColor.a > 0) {
      final r = text.backgroundRadius * scale;
      final rect = Rect.fromLTWH(
        pad - backgroundPad,
        pad - backgroundPad,
        math.min(tp.width + backgroundPad * 2, width.toDouble()),
        math.min(tp.height + backgroundPad * 2, height.toDouble()),
      );
      final paint = Paint()..color = bgColor;
      if (r > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(r)),
          paint,
        );
      } else {
        canvas.drawRect(rect, paint);
      }
    }

    // Stroke sits behind the fill so the inspector's outline controls affect
    // the actual preview instead of only being persisted in the project file.
    if (text.strokeWidth > 0) {
      final stroke =
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = text.strokeWidth * scale
            ..strokeJoin = StrokeJoin.round
            ..color = _color(text.strokeColor);
      final strokeTp = TextPainter(
        text: TextSpan(
          text: content,
          style: _fontStyle(
            text,
            fontSize: fontSize,
            fontWeight: fontWeight,
            height: lineHeight,
            letterSpacing: text.letterSpacing * scale,
            foreground: stroke,
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
    final byteData = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
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
  void clearCache() {
    _cache.clear();
    _fontsReady.clear();
  }

  TextStyle _fontStyle(
    TextContent text, {
    Color? color,
    required double fontSize,
    required FontWeight fontWeight,
    required double height,
    required double letterSpacing,
    Paint? foreground,
    List<Shadow>? shadows,
  }) {
    final base =
        text.fontFamily == 'default'
            ? const TextStyle()
            : _googleFont(text.fontFamily, fontWeight);
    return base.copyWith(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: height,
      letterSpacing: letterSpacing,
      foreground: foreground,
      shadows: shadows,
    );
  }

  String _visibleContent(TextContent text, double? localSeconds) {
    if (text.animation != 'typewriter' || localSeconds == null) {
      return text.content;
    }
    const charactersPerSecond = 24.0;
    final count =
        (localSeconds.clamp(0.0, double.infinity) * charactersPerSecond)
            .floor();
    return String.fromCharCodes(text.content.runes.take(count));
  }

  TextStyle _googleFont(String family, FontWeight weight) {
    try {
      return GoogleFonts.getFont(family, fontWeight: weight);
    } on Exception {
      // Preserve compatibility with projects that contain a custom/system
      // family not present in the Google Fonts catalog.
      return TextStyle(fontFamily: family);
    }
  }

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
