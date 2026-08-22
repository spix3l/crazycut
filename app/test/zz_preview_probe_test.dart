import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/preview_renderer.dart';
import 'package:crazycut_app/state/proxy_service.dart';

bool slate(List<int> rgba) {
  var n = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    if (rgba[i] == 40 || rgba[i] == 64) n++;
  }
  return n * 2 > rgba.length ~/ 4;
}

void main() {
  test('preview isolate probe on the real project', () async {
    final doc = ProjectDoc.decode(
        File('/Users/steve/Documents/CrazyCut/Test video.crazycut').readAsStringSync());
    final renderer = await PreviewRenderer.spawn();
    renderer.setSnapshot(doc.encode(touchModified: false));
    final mediaPaths = <String, String>{};
    for (final asset in doc.media) {
      if (asset.offline || asset.type == 'audio') continue;
      mediaPaths[asset.id] = ProxyService.decodePath(asset);
    }
    for (final t in [5.0, 20.6, 21.0, 22.166667, 25.7, 30.033333, 36.0]) {
      try {
        final f = await renderer.render(
          time: Rt.fromSeconds(t),
          width: 960,
          height: 540,
          mediaPaths: mediaPaths,
        );
        print('t=$t slate=${slate(f.rgba)}');
      } catch (e) {
        print('t=$t ERROR $e');
      }
    }
    await renderer.dispose();
  }, timeout: const Timeout(Duration(seconds: 180)));
}
