import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/editor/presentation/widgets/media_pool.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';
import 'package:crazycut_app/modules/settings/application/ui_preferences.dart';
import '../../../../support/temp_dir.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('media tabs filter the pool and import control stays compact',
      (tester) async {
    final temp = Directory.systemTemp.createTempSync('cc_media_pool');
    final doc = ProjectDoc.empty(
      'Pool',
      width: 1920,
      height: 1080,
      fps: 30,
    );
    MediaAsset asset(String id, String type) => MediaAsset(
          id: id,
          name: id,
          path: '${temp.path}/$id',
          type: type,
          duration: type == 'image' ? Rt.zero() : Rt.fromSeconds(5),
          hasAudio: type != 'image',
        );
    doc.media.addAll([
      asset('video.mp4', 'video'),
      asset('song.wav', 'audio'),
      asset('logo.svg', 'image'),
    ]);
    final controller = EditorController(
      doc,
      path: '${temp.path}/pool.crazycut',
    );
    addTearDown(() async {
      await controller.close();
      deleteTempDir(temp);
    });

    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, _) => builder(context),
        ),
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: MediaPool.width,
            height: 700,
            child: MediaPool(controller: controller),
          ),
        ),
      ),
    );

    expect(find.text('video.mp4'), findsOneWidget);
    expect(find.text('song.wav'), findsOneWidget);
    expect(find.text('logo.svg'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('media-import-control'))).height,
      38,
    );

    await tester.tap(find.text('Audios'));
    await tester.pump();

    expect(find.text('song.wav'), findsOneWidget);
    expect(find.text('video.mp4'), findsNothing);
    expect(find.text('logo.svg'), findsNothing);

    await tester.tap(find.text('Images'));
    await tester.pump();

    expect(find.text('logo.svg'), findsOneWidget);
    expect(find.text('song.wav'), findsNothing);
  });

  testWidgets('media view choice is restored and persisted', (tester) async {
    final temp = Directory.systemTemp.createTempSync('cc_media_pool_view');
    final preferences = UiPreferences(storageDirOverride: temp)
      ..mediaPoolListView = true;
    final doc = ProjectDoc.empty(
      'Pool view',
      width: 1920,
      height: 1080,
      fps: 30,
    );
    doc.media.add(
      MediaAsset(
        id: 'image',
        name: 'image.png',
        path: '${temp.path}/image.png',
        type: 'image',
        duration: Rt.zero(),
        hasAudio: false,
      ),
    );
    final controller = EditorController(
      doc,
      path: '${temp.path}/pool.crazycut',
      uiPreferences: preferences,
    );
    addTearDown(() async {
      await controller.close();
      deleteTempDir(temp);
    });

    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        pageRouteBuilder:
            <T>(settings, builder) => PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: MediaPool.width,
            height: 700,
            child: MediaPool(controller: controller),
          ),
        ),
      ),
    );

    expect(preferences.mediaPoolListView, isTrue);
    await tester.tap(find.byKey(const ValueKey('media-grid-view')));
    await tester.pump();
    expect(preferences.mediaPoolListView, isFalse);
  });
}
