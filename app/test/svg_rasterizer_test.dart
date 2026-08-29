import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/svg_rasterizer.dart';
import 'temp_dir.dart';

/// An SVG becomes a bitmap the native compositor can decode. That bitmap is
/// the clip's source, so its content has to fill it: artwork sitting in a
/// corner of a transparent canvas draws small and off-centre no matter what the
/// clip's transform says, and the on-canvas handles then surround empty space.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('cc-svg'));
  tearDown(() => deleteTempDir(tmp));

  Future<ui.Image> rasterize(String svg, {int w = 1920, int h = 1080}) async {
    final path = '${tmp.path}/icon.svg';
    File(path).writeAsStringSync(svg);
    final asset = MediaAsset(
      id: 'a',
      name: 'icon.svg',
      path: path,
      type: 'image',
      duration: Rt.fromSeconds(5),
      hasAudio: false,
    );
    final raster = await SvgRasterizer.instance.rasterize(
      asset,
      canvasWidth: w,
      canvasHeight: h,
    );
    expect(raster.width, greaterThan(0));
    final codec = await ui.instantiateImageCodec(raster.png);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, raster.width);
    expect(frame.image.height, raster.height);
    return frame.image;
  }

  /// Bounding box of the pixels that are not fully transparent.
  Future<ui.Rect> opaqueBounds(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    var left = image.width, top = image.height, right = -1, bottom = -1;
    for (var y = 0; y < image.height; y += 1) {
      for (var x = 0; x < image.width; x += 1) {
        if (bytes[(y * image.width + x) * 4 + 3] < 8) continue;
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
    expect(right, greaterThan(0), reason: 'the SVG rasterized to nothing');
    return ui.Rect.fromLTRB(
      left.toDouble(),
      top.toDouble(),
      right + 1,
      bottom + 1,
    );
  }

  test('a viewBox-only SVG fills the bitmap it is rasterized into', () async {
    // No width/height attributes: the picture is in viewBox units, which is
    // where scaling used to be skipped entirely.
    final image = await rasterize(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 509.64">'
      '<rect x="0" y="0" width="512" height="509.64" fill="#D77655"/>'
      '</svg>',
    );
    final bounds = await opaqueBounds(image);
    expect(bounds.left, lessThanOrEqualTo(1));
    expect(bounds.top, lessThanOrEqualTo(1));
    expect(bounds.right, closeTo(image.width, 1));
    expect(bounds.bottom, closeTo(image.height, 1));
    image.dispose();
  });

  test('the raster keeps the source aspect ratio', () async {
    final image = await rasterize(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">'
      '<rect x="0" y="0" width="200" height="100" fill="#3366FF"/>'
      '</svg>',
      w: 1920,
      h: 1080,
    );
    expect(image.width / image.height, closeTo(2.0, 0.01));
    // Fitted to the canvas: the wide side is what binds here.
    expect(image.width, 1920);
    final bounds = await opaqueBounds(image);
    expect(bounds.width, closeTo(image.width, 2));
    expect(bounds.height, closeTo(image.height, 2));
    image.dispose();
  });
}
