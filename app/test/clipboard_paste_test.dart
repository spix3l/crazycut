import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/clipboard_media.dart';
import 'package:crazycut_app/state/editor_controller.dart';

/// A clipboard the test writes to directly, so a paste can be exercised
/// without a window or a pasteboard.
class _FakeClipboard implements ClipboardMediaReader {
  ClipboardMedia media = ClipboardMedia.empty;
  int reads = 0;

  @override
  Future<ClipboardMedia> read() async {
    reads++;
    return media;
  }

  @override
  Future<int?> sequence() async => media.sequence;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late _FakeClipboard clipboard;
  late EditorController c;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('cc_paste');
    clipboard = _FakeClipboard();
    c = EditorController(
      ProjectDoc.empty('Paste', width: 1920, height: 1080, fps: 30),
      path: '${temp.path}${Platform.pathSeparator}p.crazycut',
      clipboard: clipboard,
    );
  });

  tearDown(() async {
    await c.close();
    c.dispose();
    temp.deleteSync(recursive: true);
  });

  Directory mediaFolder() =>
      Directory('${temp.path}${Platform.pathSeparator}Media');

  // A real 1x1 PNG, so the paste goes all the way through probing like a
  // screenshot would; the second one differs so it hashes differently.
  final redDot = Uint8List.fromList(const [
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1,
    0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84,
    120, 156, 99, 248, 207, 192, 240, 31, 0, 5, 0, 1, 255, 137, 153, 61, 29,
    0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
  ]);
  final blueDot = Uint8List.fromList(const [
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1,
    0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84,
    120, 156, 99, 96, 96, 248, 255, 31, 0, 3, 2, 1, 255, 230, 119, 11, 174,
    0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
  ]);

  test('an empty clipboard leaves the paste to the timeline', () async {
    final result = await c.importFromClipboard();
    expect(result.kind, ClipboardImportKind.nothing);
    expect(result.handled, isFalse);
  });

  test('copied files are imported, unsupported ones reported', () async {
    final file = File('${temp.path}${Platform.pathSeparator}notes.txt')
      ..writeAsStringSync('nope');
    clipboard.media = ClipboardMedia(paths: [file.path]);

    final result = await c.importFromClipboard();

    expect(result.kind, ClipboardImportKind.unsupported);
    expect(c.lastSkipped, ['notes.txt']);
  });

  test('a path that no longer exists is not treated as media', () async {
    clipboard.media = ClipboardMedia(
      paths: ['${temp.path}${Platform.pathSeparator}gone.mp4'],
    );
    expect(
      (await c.importFromClipboard()).kind,
      ClipboardImportKind.nothing,
    );
  });

  test('a pasted bitmap becomes a file in the project media folder', () async {
    clipboard.media = ClipboardMedia(image: redDot);

    final result = await c.importFromClipboard();

    expect(result.kind, ClipboardImportKind.image);
    expect(result.count, 1);
    final written = File(
      '${mediaFolder().path}${Platform.pathSeparator}Pasted image.png',
    );
    expect(written.existsSync(), isTrue);
    expect(written.readAsBytesSync(), redDot);
    expect(c.doc.media.single.type, 'image');

    // A paste is a placement: the image lands where the user is looking.
    final clip = c.doc.clips.single;
    expect(clip.mediaId, c.doc.media.single.id);
    expect(clip.start, c.playhead);
  });

  test('pasting the same bitmap twice reuses the asset', () async {
    clipboard.media = ClipboardMedia(image: redDot);
    await c.importFromClipboard();
    await c.importFromClipboard();

    expect(c.doc.media.length, 1, reason: 'deduplicated by hash (IMP-3)');
    expect(
      c.doc.clips.length,
      2,
      reason: 'the same asset can be pasted onto the timeline twice',
    );
    expect(
      mediaFolder().listSync().length,
      1,
      reason: 'the redundant copy is cleaned up, not left in the folder',
    );
  });

  test('pasting a second bitmap never clobbers the first', () async {
    clipboard.media = ClipboardMedia(image: redDot);
    await c.importFromClipboard();
    clipboard.media = ClipboardMedia(image: blueDot);
    await c.importFromClipboard();

    final names =
        mediaFolder()
            .listSync()
            .map((e) => e.path.split(Platform.pathSeparator).last)
            .toList()
          ..sort();
    expect(names, ['Pasted image 1.png', 'Pasted image.png']);
  });

  test('a copied file path pasted as text imports as a file', () async {
    final file = File('${temp.path}${Platform.pathSeparator}notes.txt')
      ..writeAsStringSync('nope');
    clipboard.media = ClipboardMedia(text: file.uri.toString());

    await c.importFromClipboard();

    expect(c.lastSkipped, ['notes.txt']);
  });

  test('plain text that is neither URL nor path falls through', () async {
    clipboard.media = const ClipboardMedia(text: 'just some words');
    expect(
      (await c.importFromClipboard()).kind,
      ClipboardImportKind.nothing,
    );
  });

  test('a clipboard untouched since a clip copy loses to the clip', () async {
    clipboard.media = ClipboardMedia(image: redDot, sequence: 4);
    c.addTextClip();
    c.copySelection();
    // The mark is taken asynchronously, as copying does not block on the OS.
    await Future<void>.delayed(Duration.zero);

    expect(
      (await c.importFromClipboard(onlyIfNewerThanCopy: true)).kind,
      ClipboardImportKind.nothing,
      reason: 'the user copied clips more recently than they copied media',
    );

    // Copying media afterwards moves the clipboard on, and media wins again.
    clipboard.media = ClipboardMedia(image: redDot, sequence: 5);
    expect(
      (await c.importFromClipboard(onlyIfNewerThanCopy: true)).kind,
      ClipboardImportKind.image,
    );
  });

  test('pasted files land in order at the playhead', () async {
    final first = File('${temp.path}${Platform.pathSeparator}a.png')
      ..writeAsBytesSync(redDot);
    final second = File('${temp.path}${Platform.pathSeparator}b.png')
      ..writeAsBytesSync(blueDot);
    clipboard.media = ClipboardMedia(paths: [first.path, second.path]);
    c.seekTo(Rt.fromSeconds(2));

    final result = await c.importFromClipboard();

    expect(result.kind, ClipboardImportKind.files);
    final clips = c.doc.clips.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    expect(clips.length, 2);
    expect(clips.first.start, Rt.fromSeconds(2));
    expect(clips.first.label, 'a.png');
    expect(clips.last.start, clips.first.start.plus(clips.first.duration));
    expect(clips.last.label, 'b.png');
  });

  test('writePastedImage creates its directory and unique names', () async {
    final dir = Directory('${temp.path}${Platform.pathSeparator}deep/nested');
    final first = await writePastedImage(redDot, directory: dir);
    final second = await writePastedImage(redDot, directory: dir);

    expect(first.path.endsWith('Pasted image.png'), isTrue);
    expect(second.path.endsWith('Pasted image 1.png'), isTrue);
  });
}
