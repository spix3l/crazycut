import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/sandbox_access.dart';
import 'temp_dir.dart';

/// Regression cover for the sandbox access rules. v0.2.1 shipped a fix that
/// bookmarked *files*, which could not restore a project: saving needs the
/// enclosing folder, and assets imported before the fix carried no grant at
/// all. These pin the folder-level contract that replaced it.
void main() {
  late Directory root;

  ProjectDoc docWith(List<String> mediaPaths) {
    final doc = ProjectDoc.empty('Access');
    for (final path in mediaPaths) {
      doc.media.add(MediaAsset(
        id: generateId(),
        name: path.split(Platform.pathSeparator).last,
        path: path,
        type: 'video',
        duration: Rt.zero(),
        hasAudio: false,
      ));
    }
    return doc;
  }

  setUp(() => root = Directory.systemTemp.createTempSync('cc_access'));
  tearDown(() => deleteTempDir(root));

  test('the project folder is required for writing, media folders for reading',
      () {
    final projectPath = '${root.path}/Show/Show.crazycut';
    final doc = docWith([
      '${root.path}/Footage/a.mp4',
      '${root.path}/Footage/b.mp4',
      '${root.path}/Music/track.wav',
    ]);

    final folders = SandboxAccess.requiredFolders(doc, projectPath);

    // The project's own folder must be writable: an atomic save creates a
    // sibling .tmp there, which a file-scoped grant would never permit.
    expect(folders['${root.path}/Show'], isTrue);
    // Media folders are only read, and each folder is asked for once no
    // matter how many clips came out of it.
    expect(folders['${root.path}/Footage'], isFalse);
    expect(folders['${root.path}/Music'], isFalse);
    expect(folders.length, 3);
  });

  test('remote assets never ask for a folder grant', () {
    final doc = docWith(['${root.path}/Footage/a.mp4']);
    doc.media.add(MediaAsset(
      id: generateId(),
      name: 'remote.mp4',
      path: 'https://example.com/remote.mp4',
      type: 'video',
      duration: Rt.zero(),
      hasAudio: false,
      sourceKind: MediaSourceKind.url,
    ));

    final folders = SandboxAccess.requiredFolders(
      doc,
      '${root.path}/Show/Show.crazycut',
    );

    expect(folders.keys, isNot(contains('https:')));
    expect(folders.length, 2);
  });

  test('canWrite distinguishes creating a new file from reading one', () {
    final dir = Directory('${root.path}/writable')..createSync();
    expect(SandboxAccess.instance.canRead(dir.path), isTrue);
    expect(SandboxAccess.instance.canWrite(dir.path), isTrue);
    // The probe must not survive the check.
    expect(dir.listSync(), isEmpty);
  });

  test('an unreachable folder fails both probes rather than throwing', () {
    final missing = '${root.path}/does-not-exist';
    expect(SandboxAccess.instance.canRead(missing), isFalse);
    expect(SandboxAccess.instance.canWrite(missing), isFalse);
  });

  test('folderOf groups every asset in a directory onto one request', () {
    expect(
      SandboxAccess.folderOf('${root.path}/Footage/a.mp4'),
      SandboxAccess.folderOf('${root.path}/Footage/b.mp4'),
    );
  });
}
