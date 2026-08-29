import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/media_relink.dart';
import 'package:crazycut_app/state/project_tools.dart';
import 'package:crazycut_app/state/svg_rasterizer.dart';
import 'temp_dir.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('cc_media_tools'));
  tearDown(() => deleteTempDir(temp));

  String normalizePath(String p) => p.replaceAll('\\', '/');

File writeFile(String relative, String content) {
    final file = File('${temp.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  MediaAsset asset(String name, String path, {String hash = ''}) => MediaAsset(
    id: name,
    name: name,
    path: path,
    type: 'video',
    duration: Rt.fromSeconds(5),
    hasAudio: true,
    hash: hash,
  );

  group('relink (IMP-15/16)', () {
    test('SVG files are accepted as media candidates', () {
      final svg = writeFile(
        'shoot/logo.svg',
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"/>',
      );

      final found = MediaRelinker.gatherCandidates([svg.path]);

      expect(found.map((file) => file.path), contains(svg.path));
    });

    test('SVG files rasterize to transparent PNG media', () async {
      final svg = writeFile(
        'shoot/logo.svg',
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
            '<circle cx="50" cy="50" r="40" fill="#ff0000"/>'
            '</svg>',
      );
      final logo = MediaAsset(
        id: 'logo',
        name: 'logo.svg',
        path: svg.path,
        type: 'image',
        duration: Rt.zero(),
        hasAudio: false,
        hash: 'sha256:test-logo',
      );

      final raster = await SvgRasterizer.instance.rasterize(
        logo,
        canvasWidth: 100,
        canvasHeight: 50,
      );

      expect((raster.width, raster.height), (50, 50));
      expect(raster.png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      expect(mediaDecodePath(logo), raster.path);
      File(raster.path).deleteSync();
    });

    test('gathers only supported media, recursively', () {
      writeFile('shoot/a.mp4', 'a');
      writeFile('shoot/nested/b.mov', 'b');
      writeFile('shoot/notes.txt', 'ignore me');

      final found = MediaRelinker.gatherCandidates(['${temp.path}/shoot']);
      final names = found.map((f) => f.uri.pathSegments.last).toList()..sort();
      expect(names, ['a.mp4', 'b.mov']);
    });

    test('matches by content hash even when the file was renamed', () {
      final moved = writeFile('shoot/renamed.mp4', 'unique-content');
      final hash = CrazyCutEngine.instance.hashFile(moved.path);

      final missing = asset('original.mp4', '/gone/original.mp4', hash: hash);
      final plan = MediaRelinker.instance.plan([
        missing,
      ], MediaRelinker.gatherCandidates(['${temp.path}/shoot']));

      expect(plan.matches, hasLength(1));
      // Candidates found by walking a directory are joined with the platform
      // separator; compare normalized so Windows agrees with the writer.
      expect(normalizePath(plan.matches.first.path), normalizePath(moved.path));
      expect(plan.matches.first.confidence, RelinkConfidence.exact);
      expect(plan.unmatched, isEmpty);
      expect(plan.summary, contains('matched by content'));
    });

    test('falls back to the filename as a proposal', () {
      final same = writeFile('shoot/clip.mp4', 'contents');
      final missing = asset('clip.mp4', '/gone/clip.mp4', hash: 'sha256:nope');

      final plan = MediaRelinker.instance.plan([
        missing,
      ], MediaRelinker.gatherCandidates([same.path]));
      expect(plan.matches.single.confidence, RelinkConfidence.proposed);
      expect(normalizePath(plan.matches.single.path), normalizePath(same.path));
    });

    test('never points two assets at the same file', () {
      final only = writeFile('shoot/clip.mp4', 'contents');
      final plan = MediaRelinker.instance.plan([
        asset('clip.mp4', '/gone/1.mp4'),
        asset('clip.mp4', '/gone/2.mp4'),
      ], MediaRelinker.gatherCandidates([only.path]));
      expect(plan.matches, hasLength(1));
      expect(plan.unmatched, hasLength(1));
      expect(plan.summary, contains('still missing'));
    });

    test('reports everything unmatched when nothing fits', () {
      writeFile('shoot/other.mp4', 'x');
      final plan = MediaRelinker.instance.plan([
        asset('clip.mp4', '/gone/clip.mp4', hash: 'sha256:nope'),
      ], MediaRelinker.gatherCandidates(['${temp.path}/shoot']));
      expect(plan.matches, isEmpty);
      expect(plan.unmatched, hasLength(1));
      expect(plan.isEmpty, isTrue);
    });
  });

  group('collect media (PRJ-14)', () {
    ProjectDoc docWithMedia(List<File> files) {
      final doc = ProjectDoc.empty(
        'Portable',
        width: 1920,
        height: 1080,
        fps: 30,
      );
      for (var i = 0; i < files.length; i++) {
        doc.media.add(asset('clip$i.mp4', files[i].path));
      }
      return doc;
    }

    test('plans the copy and reports its size before doing anything', () {
      final a = writeFile('outside/one.mp4', 'x' * 1024);
      final b = writeFile('outside/two.mp4', 'y' * 2048);
      final projectPath = '${temp.path}/project/Portable.crazycut';
      Directory('${temp.path}/project').createSync(recursive: true);

      final plan = ProjectTools.planCollect(docWithMedia([a, b]), projectPath);
      expect(plan.assets, hasLength(2));
      expect(plan.totalBytes, 1024 + 2048);
      expect(plan.sizeLabel, isNotEmpty);
      // Nothing has been copied yet.
      expect(ProjectTools.mediaFolder(projectPath).existsSync(), isFalse);
    });

    test('copies media beside the project and repoints the document', () async {
      final a = writeFile('outside/one.mp4', 'first');
      final b = writeFile('outside/two.mp4', 'second');
      final projectPath = '${temp.path}/project/Portable.crazycut';
      Directory('${temp.path}/project').createSync(recursive: true);
      final doc = docWithMedia([a, b]);

      final result = await ProjectTools.collect(doc, projectPath);
      expect(result.copied, 2);
      expect(result.error, isNull);

      final mediaDir = ProjectTools.mediaFolder(projectPath);
      expect(mediaDir.listSync(), hasLength(2));
      for (final asset in doc.media) {
        expect(asset.path.startsWith(mediaDir.path), isTrue);
        expect(File(asset.path).existsSync(), isTrue);
      }
      // The originals are left alone.
      expect(a.existsSync(), isTrue);
    });

    test('running twice does not copy the same media again', () async {
      final a = writeFile('outside/one.mp4', 'first');
      final projectPath = '${temp.path}/project/Portable.crazycut';
      Directory('${temp.path}/project').createSync(recursive: true);
      final doc = docWithMedia([a]);

      await ProjectTools.collect(doc, projectPath);
      final second = await ProjectTools.collect(doc, projectPath);
      expect(second.copied, 0);
      expect(second.skipped, 1);
      expect(ProjectTools.mediaFolder(projectPath).listSync(), hasLength(1));
    });

    test('two sources with one filename both survive', () async {
      final a = writeFile('outsideA/clip.mp4', 'A');
      final b = writeFile('outsideB/clip.mp4', 'B');
      final projectPath = '${temp.path}/project/Portable.crazycut';
      Directory('${temp.path}/project').createSync(recursive: true);
      final doc =
          ProjectDoc.empty('P', width: 1920, height: 1080, fps: 30)
            ..media.add(asset('clip.mp4', a.path))
            ..media.add(asset('clip.mp4', b.path));

      await ProjectTools.collect(doc, projectPath);
      final copies = ProjectTools.mediaFolder(projectPath).listSync();
      expect(copies, hasLength(2));
      expect(doc.media[0].path, isNot(doc.media[1].path));
      expect(File(doc.media[0].path).readAsStringSync(), 'A');
      expect(File(doc.media[1].path).readAsStringSync(), 'B');
    });

    test('offline media is reported, not copied', () {
      final projectPath = '${temp.path}/project/Portable.crazycut';
      Directory('${temp.path}/project').createSync(recursive: true);
      final doc = ProjectDoc.empty('P', width: 1920, height: 1080, fps: 30)
        ..media.add(asset('gone.mp4', '/nope/gone.mp4'));

      final plan = ProjectTools.planCollect(doc, projectPath);
      expect(plan.assets, isEmpty);
      expect(plan.missing, hasLength(1));
    });
  });

  group('diagnostics', () {
    test('writes a readable bundle next to the project', () async {
      final projectPath = '${temp.path}/project/Portable.crazycut';
      Directory('${temp.path}/project').createSync(recursive: true);
      final doc = ProjectDoc.empty('P', width: 1920, height: 1080, fps: 30)
        ..media.add(asset('gone.mp4', '/nope/gone.mp4')..offline = true);

      final file = await ProjectTools.writeDiagnostics(
        doc: doc,
        projectPath: projectPath,
        engineLib: '/tmp/libcrazycut.dylib',
      );
      expect(file.existsSync(), isTrue);
      expect(file.parent.path, '${temp.path}/project');

      final report =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect((report['app'] as Map)['platform'], Platform.operatingSystem);
      expect((report['engine'] as Map)['library'], '/tmp/libcrazycut.dylib');
      final project = report['project'] as Map<String, dynamic>;
      expect((project['counts'] as Map)['media'], 1);
      expect(project['offlineMedia'], ['/nope/gone.mp4']);
    });
  });
}
