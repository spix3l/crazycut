import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/media_url_service.dart';
import 'package:crazycut_app/state/project_tools.dart';
import 'temp_dir.dart';

void main() {
  test('normalizes URLs without changing meaningful query order', () {
    expect(
      normalizeRemoteUrl('HTTPS://Example.COM:443/a%20b.mp4?b=2&a=1#clip'),
      'https://example.com/a%20b.mp4?b=2&a=1',
    );
    expect(
      () => normalizeRemoteUrl('ftp://example.com/video.mp4'),
      throwsA(isA<MediaUrlException>()),
    );
    expect(
      () => normalizeRemoteUrl('https://user:secret@example.com/a.mp4'),
      throwsA(isA<MediaUrlException>()),
    );
  });

  test('recognizes common YouTube URLs and their starting time', () {
    expect(
      parseYouTubeLink('https://youtu.be/M7lc1UVf-VE?t=1m12s')?.videoId,
      'M7lc1UVf-VE',
    );
    expect(
      parseYouTubeLink('https://youtube.com/shorts/M7lc1UVf-VE')?.videoId,
      'M7lc1UVf-VE',
    );
    expect(
      parseYouTubeLink(
        'https://youtube.com/watch?v=M7lc1UVf-VE&t=72',
      )?.startSeconds,
      72,
    );
    expect(parseYouTubeLink('https://example.com/watch?v=M7lc1UVf-VE'), isNull);
  });

  test('remote source and YouTube reference survive project JSON', () {
    final doc = ProjectDoc.empty('Remote');
    doc.media.add(
      MediaAsset(
        id: 'remote',
        name: 'clip.mp4',
        path: 'https://cdn.example/clip.mp4',
        type: 'video',
        duration: Rt.fromSeconds(5),
        hasAudio: true,
        sourceKind: MediaSourceKind.url,
        remoteEtag: 'v1',
        remoteContentLength: 42,
      ),
    );
    doc.references.add(
      MediaReference(
        id: 'yt',
        provider: 'youtube',
        url: 'https://youtu.be/M7lc1UVf-VE',
        externalId: 'M7lc1UVf-VE',
        rangeIn: Rt.fromSeconds(2),
        rangeOut: Rt.fromSeconds(7),
      ),
    );

    final loaded = ProjectDoc.decode(doc.encode(touchModified: false));
    expect(loaded.media.single.isRemote, isTrue);
    expect(loaded.media.single.remoteEtag, 'v1');
    expect(loaded.references.single.externalId, 'M7lc1UVf-VE');
    expect(loaded.references.single.rangeOut, Rt.fromSeconds(7));

    final legacy =
        jsonDecode(doc.encode(touchModified: false)) as Map<String, dynamic>;
    (legacy['media'] as List).first.remove('sourceKind');
    expect(ProjectDoc.fromJson(legacy).media.single.isRemote, isFalse);
  });

  test('inspects direct media headers and rejects HTML pages', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      if (request.uri.path == '/page') {
        request.response.headers.contentType = ContentType.html;
      } else {
        request.response.headers
          ..contentType = ContentType('video', 'mp4')
          ..set('etag', 'fixture-v1')
          ..contentLength = 123;
      }
      request.response.close();
    });
    final service = MediaUrlService();
    addTearDown(service.close);
    final base = 'http://${server.address.host}:${server.port}';

    final media = await service.inspect('$base/clip.mp4');
    expect(media.name, 'clip.mp4');
    expect(media.contentType, 'video/mp4');
    expect(media.etag, 'fixture-v1');

    expect(service.inspect('$base/page'), throwsA(isA<MediaUrlException>()));
  });

  test('collect downloads a remote source and converts it to a file', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final temp = Directory.systemTemp.createTempSync('cc_remote_collect');
    addTearDown(() async {
      await server.close(force: true);
      deleteTempDir(temp);
    });
    server.listen((request) async {
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final doc = ProjectDoc.empty('Remote')
      ..media.add(
        MediaAsset(
          id: 'remote',
          name: 'remote.mp4',
          path: 'http://${server.address.host}:${server.port}/remote.mp4',
          type: 'video',
          duration: Rt.fromSeconds(1),
          hasAudio: false,
          sourceKind: MediaSourceKind.url,
          remoteContentLength: 4,
        ),
      );
    final projectPath = '${temp.path}/project/Remote.crazycut';
    Directory('${temp.path}/project').createSync(recursive: true);

    final result = await ProjectTools.collect(doc, projectPath);

    expect(result.copied, 1);
    expect(doc.media.single.isRemote, isFalse);
    expect(File(doc.media.single.path).readAsBytesSync(), [1, 2, 3, 4]);
  });

  test(
    'FFmpeg probes a direct HTTP video URL',
    () async {
      final fixture = File('../fixtures/media/sample.mp4');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final length = fixture.lengthSync();
        final range = request.headers.value(HttpHeaders.rangeHeader);
        var start = 0;
        var end = length - 1;
        if (range != null) {
          final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
          if (match != null) {
            start = int.parse(match.group(1)!);
            end = int.tryParse(match.group(2) ?? '') ?? end;
            request.response
              ..statusCode = HttpStatus.partialContent
              ..headers.set(
                HttpHeaders.contentRangeHeader,
                'bytes $start-$end/$length',
              );
          }
        }
        request.response.headers
          ..contentType = ContentType('video', 'mp4')
          ..contentLength = end - start + 1
          ..set(HttpHeaders.acceptRangesHeader, 'bytes');
        if (request.method != 'HEAD') {
          await request.response.addStream(fixture.openRead(start, end + 1));
        }
        await request.response.close();
      });
      final service = MediaUrlService();
      addTearDown(service.close);
      final descriptor = await service.inspect(
        'http://${server.address.host}:${server.port}/sample.mp4',
      );

      final probe = await service.probe(descriptor);

      expect(probe.type, 'video');
      expect(probe.width, 640);
      expect(probe.height, 360);
    },
    skip: !File('../fixtures/media/sample.mp4').existsSync(),
    tags: 'engine',
  );
}
