import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/text_content.dart';
import 'package:crazycut_app/state/text_rasterizer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => TextRasterizer.instance.clearCache());

  test(
    'font size is scaled to the render height, not fitted to the canvas',
    () async {
      final raster = await TextRasterizer.instance.render(
        TextContent(content: 'Caption', fontSize: 64),
        canvasWidth: 960,
        sequenceHeight: 540,
      );

      expect(raster, isNotNull);
      expect(raster!.width, lessThan(300));
      expect(raster.height, inInclusiveRange(24, 80));
    },
  );

  test('typewriter raster exposes progressively more content', () async {
    final text = TextContent(
      content: 'Progressive title',
      fontSize: 96,
      animation: 'typewriter',
    );
    final empty = await TextRasterizer.instance.render(
      text,
      canvasWidth: 960,
      sequenceHeight: 540,
      localSeconds: 0,
    );
    final partial = await TextRasterizer.instance.render(
      text,
      canvasWidth: 960,
      sequenceHeight: 540,
      localSeconds: 0.2,
    );
    final complete = await TextRasterizer.instance.render(
      text,
      canvasWidth: 960,
      sequenceHeight: 540,
      localSeconds: 10,
    );

    expect(empty, isNull);
    expect(partial, isNotNull);
    expect(complete, isNotNull);
    expect(partial!.width, lessThan(complete!.width));
  });

  test(
    'real shadow blur expands the raster instead of clipping the effect',
    () async {
      final plain = await TextRasterizer.instance.render(
        TextContent(content: 'Shadow', fontSize: 72),
        canvasWidth: 960,
        sequenceHeight: 540,
      );
      final shadowed = await TextRasterizer.instance.render(
        TextContent(
          content: 'Shadow',
          fontSize: 72,
          shadowOpacity: 0.8,
          shadowBlur: 24,
          shadowOffsetX: 12,
          shadowOffsetY: 12,
        ),
        canvasWidth: 960,
        sequenceHeight: 540,
      );

      expect(shadowed!.width, greaterThan(plain!.width));
      expect(shadowed.height, greaterThan(plain.height));
    },
  );
}
