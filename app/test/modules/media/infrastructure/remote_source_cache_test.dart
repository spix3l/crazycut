import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/media/infrastructure/media_cache.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/media/infrastructure/remote_source_cache.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/infrastructure/svg_rasterizer.dart';

void main() {

  late HttpServer server;
  late String base;
  var hits = 0;
  final bytes = List<int>.generate(2048, (i) => i % 251);

  setUp(() async {
    hits = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    server.listen((request) async {
      hits += 1;
      if (request.uri.path == '/broken.gif') {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType('image', 'gif');
      request.response.add(bytes);
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  MediaAsset remote(String path, {int? contentLength}) => MediaAsset(
    id: 'a${DateTime.now().microsecondsSinceEpoch}',
    name: 'loop.gif',
    path: '$base$path',
    type: 'video',
    duration: Rt.fromSeconds(2),
    hasAudio: false,
    sourceKind: MediaSourceKind.url,
    remoteContentLength: contentLength,
  );

  void cleanUp(MediaAsset asset) {
    addTearDown(() {
      final mirror = localRemoteSource(asset);
      if (mirror != null) File(mirror).deleteSync();
    });
  }

  test('mirrors a URL source once and decodes from the local copy', () async {
    final asset = remote('/loop.gif');
    cleanUp(asset);
    expect(mediaDecodePath(asset), asset.path);

    final mirror = await RemoteSourceCache.instance.ensure(asset);
    expect(mirror, isNotNull);
    expect(File(mirror!).readAsBytesSync(), bytes);
    expect(mirror, endsWith('.gif'));
    // Every decoder — preview, filmstrip, proxy, export — now reads the file.
    expect(mediaDecodePath(asset), mirror);
    expect(hits, 1);

    // A second request is answered from disk, and the path survives a
    // save/reload because it rides in the asset's extra fields.
    expect(await RemoteSourceCache.instance.ensure(asset), mirror);
    expect(hits, 1);

    final doc = ProjectDoc.empty('mirror')..media.add(asset);
    final reloaded = ProjectDoc.decode(doc.encode(touchModified: false));
    expect(mediaDecodePath(reloaded.media.single), mirror);
  });

  test('leaves the URL in place when the source is too large', () async {
    final asset = remote(
      '/huge.gif',
      contentLength: kMaxMirroredRemoteBytes + 1,
    );
    expect(await RemoteSourceCache.instance.ensure(asset), isNull);
    expect(hits, 0);
    expect(mediaDecodePath(asset), asset.path);
  });

  test('falls back to streaming and leaves no partial file on failure',
      () async {
    final asset = remote('/broken.gif');
    expect(await RemoteSourceCache.instance.ensure(asset), isNull);
    expect(mediaDecodePath(asset), asset.path);
    final cache = await MediaCache.instance.dir();
    expect(
      cache.listSync().whereType<File>().where(
        (f) => f.path.contains(asset.id),
      ),
      isEmpty,
    );
  });

  test('invalidating an asset drops its mirror', () async {
    final asset = remote('/loop.gif');
    cleanUp(asset);
    final mirror = await RemoteSourceCache.instance.ensure(asset);
    expect(mirror, isNotNull);

    await MediaCache.instance.invalidate(asset);
    expect(localRemoteSource(asset), isNull);
    expect(File(mirror!).existsSync(), isFalse);
    expect(mediaDecodePath(asset), asset.path);

    // The next refresh downloads the new bytes rather than reusing stale ones.
    expect(await RemoteSourceCache.instance.ensure(asset), isNotNull);
    expect(hits, 2);
  });
}
