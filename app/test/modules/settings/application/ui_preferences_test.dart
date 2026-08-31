import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';
import 'package:crazycut_app/modules/settings/application/ui_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('crazycut-ui-preferences-');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('all UI preferences survive a reload', () async {
    final preferences = UiPreferences(storageDirOverride: dir);
    await preferences.load();

    preferences
      ..setTimelineSnap(false)
      ..setTimelinePixelsPerSecond(93.5)
      ..setMediaPoolListView(true)
      ..setMagneticTimeline(true)
      ..setLinkAudioOnAdd(false)
      ..setPreviewZoom('pct50')
      ..setPreviewQuality('half')
      ..setShowSafeMargins(true)
      ..setShowCanvasGrid(true)
      ..setGenerateProxies(false)
      ..setOutputDeviceName('Studio Display');
    await preferences.flush();

    final restored = UiPreferences(storageDirOverride: dir);
    await restored.load();

    expect(restored.timelineSnap, isFalse);
    expect(restored.timelinePixelsPerSecond, 93.5);
    expect(restored.mediaPoolListView, isTrue);
    expect(restored.magneticTimeline, isTrue);
    expect(restored.linkAudioOnAdd, isFalse);
    expect(restored.previewZoom, 'pct50');
    expect(restored.previewQuality, 'half');
    expect(restored.showSafeMargins, isTrue);
    expect(restored.showCanvasGrid, isTrue);
    expect(restored.generateProxies, isFalse);
    expect(restored.outputDeviceName, 'Studio Display');
  });

  test('timeline zoom is clamped before it is stored', () async {
    final preferences = UiPreferences(storageDirOverride: dir);
    preferences.setTimelinePixelsPerSecond(1000);
    await preferences.flush();

    final restored = UiPreferences(storageDirOverride: dir);
    await restored.load();
    expect(restored.timelinePixelsPerSecond, 160);
  });

  test('editor controller restores and persists its UI choices', () async {
    final preferences =
        UiPreferences(storageDirOverride: dir)
          ..setMagneticTimeline(true)
          ..setLinkAudioOnAdd(false)
          ..setPreviewZoom('pct50')
          ..setPreviewQuality('half')
          ..setShowSafeMargins(true)
          ..setShowCanvasGrid(true)
          ..setOutputDeviceName('External Output');
    await preferences.flush();

    final controller = EditorController(
      ProjectDoc.empty('Preferences', width: 1920, height: 1080, fps: 30),
      path: '${dir.path}/preferences.crazycut',
      uiPreferences: preferences,
    );
    expect(controller.magnetic, isTrue);
    expect(controller.linkAudioOnAdd, isFalse);
    expect(controller.previewZoom, PreviewZoom.pct50);
    expect(controller.previewQuality, PreviewQuality.half);
    expect(controller.showSafeMargins, isTrue);
    expect(controller.showCanvasGrid, isTrue);
    expect(controller.outputDeviceName, 'External Output');

    controller
      ..setMagnetic(false)
      ..setLinkAudioOnAdd(true)
      ..setPreviewZoom(PreviewZoom.pct100)
      ..setShowSafeMargins(false)
      ..setShowCanvasGrid(false)
      ..setOutputDevice('');
    await preferences.flush();
    await controller.close();

    final restored = UiPreferences(storageDirOverride: dir);
    await restored.load();
    expect(restored.magneticTimeline, isFalse);
    expect(restored.linkAudioOnAdd, isTrue);
    expect(restored.previewZoom, 'pct100');
    expect(restored.previewQuality, 'half');
    expect(restored.showSafeMargins, isFalse);
    expect(restored.showCanvasGrid, isFalse);
    expect(restored.outputDeviceName, isEmpty);
  });
}
