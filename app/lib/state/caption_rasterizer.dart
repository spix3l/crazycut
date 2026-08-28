import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'package:crazycut_app/data/caption.dart';
import 'package:crazycut_app/models/rational.dart';

/// Stable key shared by the Flutter preview/export preparation and the native
/// compositor. Highlight variants are separate immutable textures, so the
/// worker never has to shape text in the frame loop.
String captionTextureKey(
  CaptionTrack track,
  CaptionItem item, {
  int? highlightedWord,
}) =>
    'caption:${track.id}:${item.id}'
    '${highlightedWord == null ? '' : ':h:$highlightedWord'}';

int? activeCaptionWord(CaptionTrack track, CaptionItem item, Rt time) {
  if (!track.style.highlightWords) return null;
  for (var i = 0; i < item.words.length; i++) {
    final word = item.words[i];
    if (time >= word.start && time < word.end) return i;
  }
  return null;
}

/// Flutter-owned caption shaping used by both preview and export.
///
/// The result is a tight straight-alpha RGBA texture. Placement is deliberately
/// left to the native renderer, which reads the normalized position from the
/// same caption style snapshot for preview and export.
class CaptionRasterizer {
  CaptionRasterizer._();
  static final CaptionRasterizer instance = CaptionRasterizer._();

  static const int _cacheLimit = 96;
  final Map<String, RasterizedCaption> _cache = {};

  Future<RasterizedCaption?> render(
    CaptionTrack track,
    CaptionItem item, {
    required int canvasWidth,
    required int sequenceHeight,
    int? highlightedWord,
  }) async {
    if (item.text.trim().isEmpty || canvasWidth <= 0 || sequenceHeight <= 0) {
      return null;
    }
    final style = track.style;
    final family = style.fontFamily.trim();

    final key = jsonEncode({
      'track': track.id,
      'item': item.toJson(),
      'style': style.toJson(),
      'highlight': highlightedWord,
      'width': canvasWidth,
      'height': sequenceHeight,
    });
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }

    final scale = sequenceHeight / 1080.0;
    final fontSize = (style.fontSize * scale).clamp(4.0, 512.0).toDouble();
    final maxWidth = (canvasWidth * style.maxWidth.clamp(0.1, 1.0)).clamp(
      16.0,
      canvasWidth.toDouble(),
    );
    final textStyle = _fontStyle(
      family,
      color: _color(style.textColor),
      size: fontSize,
    );
    final spans = _spans(item, textStyle, style, highlightedWord);
    final painter = TextPainter(
      text: TextSpan(children: spans),
      textAlign: _alignment(style.alignment),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: maxWidth);

    final pad = math.max(4.0, fontSize * 0.22).ceil();
    final width = (painter.width.ceil() + pad * 2).clamp(4, canvasWidth);
    final height = (painter.height.ceil() + pad * 2).clamp(4, 4096);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final background = _color(style.backgroundColor);
    if (background.a > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          Radius.circular(fontSize * 0.15),
        ),
        Paint()..color = background,
      );
    }
    painter.paint(canvas, Offset(pad.toDouble(), pad.toDouble()));
    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);
    final bytes = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    picture.dispose();
    if (bytes == null) return null;
    final result = RasterizedCaption(
      bytes: bytes.buffer.asUint8List(),
      width: width,
      height: height,
    );
    _cache[key] = result;
    if (_cache.length > _cacheLimit) _cache.remove(_cache.keys.first);
    return result;
  }

  List<InlineSpan> _spans(
    CaptionItem item,
    TextStyle base,
    CaptionStyle style,
    int? highlightedWord,
  ) {
    if (highlightedWord == null ||
        highlightedWord < 0 ||
        highlightedWord >= item.words.length) {
      return [TextSpan(text: item.text, style: base)];
    }
    final target = item.words[highlightedWord].text.trim();
    if (target.isEmpty) return [TextSpan(text: item.text, style: base)];

    // Word timings may have punctuation-normalized recognition text. Find the
    // words in order instead of rebuilding cue text, preserving the user's
    // exact spacing, punctuation, and line breaks.
    var searchFrom = 0;
    for (var i = 0; i <= highlightedWord; i++) {
      final needle = item.words[i].text.trim();
      if (needle.isEmpty) continue;
      final found = item.text.toLowerCase().indexOf(
        needle.toLowerCase(),
        searchFrom,
      );
      if (found < 0) {
        if (i == highlightedWord) {
          return [TextSpan(text: item.text, style: base)];
        }
        continue;
      }
      if (i == highlightedWord) {
        return [
          if (found > 0)
            TextSpan(text: item.text.substring(0, found), style: base),
          TextSpan(
            text: item.text.substring(found, found + needle.length),
            style: base.copyWith(color: _color(style.highlightColor)),
          ),
          if (found + needle.length < item.text.length)
            TextSpan(
              text: item.text.substring(found + needle.length),
              style: base,
            ),
        ];
      }
      searchFrom = found + needle.length;
    }
    return [TextSpan(text: item.text, style: base)];
  }

  TextStyle _fontStyle(
    String family, {
    required Color color,
    required double size,
  }) {
    final base =
        family.isEmpty || family == 'default'
            ? const TextStyle()
            : TextStyle(fontFamily: family);
    return base.copyWith(
      color: color,
      fontSize: size,
      fontWeight: FontWeight.w700,
      height: 1.18,
      shadows: const [
        Shadow(color: Color(0xB0000000), blurRadius: 5, offset: Offset(0, 2)),
      ],
    );
  }

  TextAlign _alignment(String value) => switch (value) {
    'left' => TextAlign.left,
    'right' => TextAlign.right,
    _ => TextAlign.center,
  };

  /// Caption style colours are serialized as CSS-like #RRGGBBAA.
  Color _color(String value) {
    var hex = value.replaceFirst('#', '');
    if (hex.length == 6) hex = '${hex}FF';
    final rgba = int.tryParse(hex, radix: 16) ?? 0xFFFFFFFF;
    final argb = ((rgba & 0xFF) << 24) | (rgba >> 8);
    return Color(argb);
  }

  void clearCache() {
    _cache.clear();
  }
}

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
