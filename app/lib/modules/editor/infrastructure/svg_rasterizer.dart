import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

import 'package:crazycut_app/modules/media/infrastructure/cache_dir.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/media/infrastructure/remote_source_cache.dart';

part 'svg_raster.dart';

const _svgRasterPathKey = 'svgRasterPath';

/// Bumped whenever the rasterizer's output changes. It rides in the cache file
/// name so a project that still points at a bitmap from an older, wrong
/// rasterization re-renders it instead of loading the bad pixels forever.
const _svgRasterVersion = 2;

bool isSvgPath(String path) {
  final uri = Uri.tryParse(path);
  return (uri?.path ?? path).toLowerCase().endsWith('.svg');
}

/// Returns the file the native renderer should decode for [asset].
///
/// For an SVG that is the rasterized bitmap; for a URL-imported source it is
/// the local mirror once [RemoteSourceCache] has written one, which is what
/// makes seeking a remote clip cost a disk read instead of an HTTP round trip.
/// The original path remains the project source and is still used for relink,
/// collect-media, hashing and reveal-in-folder.
String mediaDecodePath(MediaAsset asset) {
  final raster = asset.extra[_svgRasterPathKey];
  if (raster is String && _isCurrentRaster(raster)) return raster;
  return localRemoteSource(asset) ?? asset.path;
}

bool _isCurrentRaster(String path) =>
    path.contains('-svg$_svgRasterVersion-') && File(path).existsSync();

/// True when [asset] is an SVG with no usable bitmap behind it — never
/// rasterized, cache evicted, or rasterized by an older version.
bool needsSvgRaster(MediaAsset asset) {
  if (!isSvgPath(asset.path)) return false;
  final raster = asset.extra[_svgRasterPathKey];
  return !(raster is String && _isCurrentRaster(raster));
}

/// Converts SVG sources to transparent PNGs for FFmpeg-based preview/export.
class SvgRasterizer {
  SvgRasterizer._();

  static final SvgRasterizer instance = SvgRasterizer._();

  Future<SvgRaster> rasterize(
    MediaAsset asset, {
    required int canvasWidth,
    required int canvasHeight,
  }) async {
    final SvgLoader<void> loader;
    if (asset.isRemote) {
      final response = await http.get(Uri.parse(asset.path));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('SVG server returned HTTP ${response.statusCode}');
      }
      if (response.bodyBytes.length > 10 << 20) {
        throw StateError('Remote SVG exceeds the 10 MB safety limit');
      }
      loader = SvgBytesLoader(response.bodyBytes);
    } else {
      loader = SvgFileLoader(File(asset.path));
    }
    final info = await vg.loadPicture(loader, null);
    try {
      final sourceWidth =
          info.size.width.isFinite && info.size.width > 0
              ? info.size.width
              : math.max(1, canvasWidth).toDouble();
      final sourceHeight =
          info.size.height.isFinite && info.size.height > 0
              ? info.size.height
              : math.max(1, canvasHeight).toDouble();
      final scale = math.min(
        math.max(1, canvasWidth) / sourceWidth,
        math.max(1, canvasHeight) / sourceHeight,
      );
      final width = math.max(1, (sourceWidth * scale).round());
      final height = math.max(1, (sourceHeight * scale).round());
      // The picture draws in the SVG's own units (its viewBox), and
      // `Picture.toImage` only chooses how much of that space to keep — it does
      // not fit the drawing to the bitmap. Rasterizing it directly left the
      // artwork at viewBox size in the top-left corner with transparent padding
      // for the rest, so every SVG landed small and off-centre on the canvas
      // while its transform said it was centred. Scale first, then rasterize.
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
        ..scale(scale)
        ..drawPicture(info.picture);
      final scaled = recorder.endRecording();
      final ui.Image image;
      try {
        image = await scaled.toImage(width, height);
      } finally {
        scaled.dispose();
      }
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) {
          throw StateError('SVG rasterization returned no pixels');
        }
        final png = data.buffer.asUint8List();
        final cache = await mediaCacheDirectory();
        final key = mediaCacheKey(hash: asset.hash, id: asset.id);
        final file = File(
          '${cache.path}${Platform.pathSeparator}'
          '$key-svg$_svgRasterVersion-${width}x$height.png',
        );
        await file.writeAsBytes(png, flush: false);
        asset.extra[_svgRasterPathKey] = file.path;
        return SvgRaster(
          path: file.path,
          width: width,
          height: height,
          png: png,
        );
      } finally {
        image.dispose();
      }
    } finally {
      info.picture.dispose();
    }
  }
}
