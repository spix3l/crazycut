import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/editor/presentation/models/editor_models.dart';
import 'package:crazycut_app/modules/editor/presentation/widgets/timeline/timeline_panel.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';
import '../../support/temp_dir.dart';

void main() {
  test('timeline zoom conversions are inverse and clamp to their bounds', () {
    expect(timelinePixelsPerSecondForZoom(-1), kMinPxPerSec);
    expect(timelinePixelsPerSecondForZoom(0), kMinPxPerSec);
    expect(timelinePixelsPerSecondForZoom(1), kMaxPxPerSec);
    expect(timelinePixelsPerSecondForZoom(2), kMaxPxPerSec);

    for (final pixels in [kMinPxPerSec, 12.0, 40.0, 96.0, kMaxPxPerSec]) {
      final zoom = timelineZoomForPixelsPerSecond(pixels);
      expect(timelinePixelsPerSecondForZoom(zoom), closeTo(pixels, 0.000001));
    }
  });

  test('lanes shrink as the timeline zooms out and stay full size zoomed in',
      () {
    expect(timelineLaneScaleForPixelsPerSecond(kMaxPxPerSec), 1.0);
    expect(timelineLaneScaleForPixelsPerSecond(kPixelsPerSecond), 1.0);
    expect(timelineLaneScaleForPixelsPerSecond(kMinPxPerSec), 0.5);
    // Halfway between min and default zoom the lanes sit at three quarters.
    expect(
      timelineLaneScaleForPixelsPerSecond(
        (kMinPxPerSec + kPixelsPerSecond) / 2,
      ),
      closeTo(0.75, 0.000001),
    );
  });

  test('repeated toolbar-sized zoom steps keep moving in one direction', () {
    var pixels = kPixelsPerSecond;
    final zoomedIn = <double>[];
    for (var i = 0; i < 4; i++) {
      final current = timelineZoomForPixelsPerSecond(pixels);
      pixels = timelinePixelsPerSecondForZoom(current + 0.1);
      zoomedIn.add(pixels);
    }
    expect(zoomedIn, orderedEquals([...zoomedIn]..sort()));
    expect(zoomedIn.toSet(), hasLength(4));

    final zoomedOut = <double>[];
    for (var i = 0; i < 4; i++) {
      final current = timelineZoomForPixelsPerSecond(pixels);
      pixels = timelinePixelsPerSecondForZoom(current - 0.1);
      zoomedOut.add(pixels);
    }
    expect(
      zoomedOut,
      orderedEquals([...zoomedOut]..sort((a, b) => b.compareTo(a))),
    );
    expect(zoomedOut.toSet(), hasLength(4));
  });

  testWidgets('timeline zoom buttons keep slider units synchronized', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final temp = Directory.systemTemp.createTempSync('crazycut-zoom-');
    final controller = EditorController(
      ProjectDoc.empty('Zoom', width: 1920, height: 1080, fps: 30),
      path: '${temp.path}/zoom.crazycut',
    );
    addTearDown(() async {
      await controller.close();
      if (temp.existsSync()) deleteTempDir(temp);
    });

    var pixels = kPixelsPerSecond;
    final values = <double>[];
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        pageRouteBuilder:
            <T>(settings, builder) => PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: StatefulBuilder(
          builder:
              (context, setState) => Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 1200,
                  height: 400,
                  child: TimelinePanel(
                    controller: controller,
                    pxPerSec: pixels,
                    snap: false,
                    onZoomChanged: (zoom) {
                      setState(() {
                        pixels = timelinePixelsPerSecondForZoom(zoom);
                        values.add(pixels);
                      });
                    },
                  ),
                ),
              ),
        ),
      ),
    );

    Finder button(IconData icon) => find.byWidgetPredicate(
      (widget) => widget is CcIcon && widget.icon == icon,
    );

    for (var i = 0; i < 4; i++) {
      await tester.tap(button(LucideIcons.zoomIn));
      await tester.pump();
    }
    expect(values, hasLength(4));
    for (var i = 1; i < values.length; i++) {
      expect(values[i], greaterThan(values[i - 1]));
    }

    values.clear();
    for (var i = 0; i < 4; i++) {
      await tester.tap(button(LucideIcons.zoomOut));
      await tester.pump();
    }
    expect(values, hasLength(4));
    for (var i = 1; i < values.length; i++) {
      expect(values[i], lessThan(values[i - 1]));
    }
  });

  test('GIF paths remain accepted case-insensitively by the import filter', () {
    expect(kSupportedExtensions, contains('gif'));
    expect(
      kSupportedExtensions.contains(
        'ANIMATION.GIF'.split('.').last.toLowerCase(),
      ),
      isTrue,
    );
  });
}
