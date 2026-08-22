import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/state/editor_controller.dart';
import 'package:crazycut_app/state/proxy_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a session-owned proxy service survives closing and reopening',
    () async {
      final temp = await Directory.systemTemp.createTemp('cc-proxy-lifecycle');
      final proxies = ProxyService();
      EditorController? second;

      try {
        final first = EditorController(
          ProjectDoc.empty('First', width: 1920, height: 1080, fps: 30),
          path: '${temp.path}/first.crazycut',
          proxies: proxies,
        );

        await first.close();
        first.dispose();

        expect(() {
          second = EditorController(
            ProjectDoc.empty('Second', width: 1920, height: 1080, fps: 30),
            path: '${temp.path}/second.crazycut',
            proxies: proxies,
          );
        }, returnsNormally);

        await second!.close();
        second!.dispose();
      } finally {
        proxies.dispose();
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
  );
}
