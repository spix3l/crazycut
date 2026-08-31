import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/project/infrastructure/autosave.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/project/infrastructure/repository.dart';
import 'package:crazycut_app/core/math/rational.dart';
import '../../support/temp_dir.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('crazycut-test');
    ProjectRepository.rootOverride = root;
  });

  tearDown(() {
    ProjectRepository.rootOverride = null;
    if (root.existsSync()) deleteTempDir(root);
  });

  ProjectDoc project(String name) {
    final doc = ProjectDoc.empty(name);
    doc.clips.add(Clip(
      id: 'c1',
      trackId: doc.videoTrack()!.id,
      mediaId: 'm1',
      label: 'clip',
      start: Rt.zero(),
      duration: Rt.fromSeconds(5),
      sourceIn: Rt.zero(),
    ));
    return doc;
  }

  test('saving writes atomically and lists in the browser', () async {
    final doc = project('Alpha');
    final file = await ProjectRepository.projectFile(doc.name);
    await ProjectRepository.save(doc, path: file.path);

    final listed = await ProjectRepository.listProjects();
    expect(listed, hasLength(1));
    expect(listed.single.$2.name, 'Alpha');
    // No temp file is left behind.
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  test('autosave writes a sidecar, a full save clears it (PRJ-6)', () async {
    final doc = project('Beta');
    final file = await ProjectRepository.projectFile(doc.name);
    await ProjectRepository.save(doc, path: file.path);

    final autosave = ProjectAutosave(
      doc,
      path: file.path,
      debounce: const Duration(milliseconds: 10),
    );
    doc.clips.single.start = Rt.fromSeconds(3);
    autosave.markDirty();
    await autosave.writeAutosave();

    final sidecar = ProjectRepository.autosaveFor(file.path);
    expect(sidecar.existsSync(), isTrue);
    expect(autosave.state, SaveState.dirty);

    await autosave.saveNow();
    expect(sidecar.existsSync(), isFalse);
    expect(autosave.state, SaveState.saved);
    expect(autosave.isDirty, isFalse);
    autosave.dispose();
  });

  test('the backup ring keeps the newest N (PRJ-7)', () async {
    final doc = project('Gamma');
    final file = await ProjectRepository.projectFile(doc.name);
    await ProjectRepository.save(doc, path: file.path);

    for (var i = 0; i < 5; i++) {
      await ProjectRepository.writeBackup(doc, file.path, keep: 3);
      // Timestamps have second resolution in the filename; nudge the clock.
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final backups = await ProjectRepository.backupsFor(file.path);
    expect(backups.length, lessThanOrEqualTo(3));
  });

  test('an unclean exit is recoverable and loses only the autosave window '
      '(PRJ-8, criterion 1)', () async {
    final doc = project('Delta');
    final file = await ProjectRepository.projectFile(doc.name);
    await ProjectRepository.save(doc, path: file.path);

    // Simulate editing that only reached the autosave before a kill -9.
    final autosave = ProjectAutosave(doc, path: file.path);
    doc.clips.single.start = Rt.fromSeconds(7);
    autosave.markDirty();
    await autosave.writeAutosave();
    autosave.dispose();
    // Make the sidecar unambiguously newer than the project file.
    ProjectRepository.autosaveFor(file.path)
        .setLastModifiedSync(DateTime.now().add(const Duration(seconds: 2)));

    final candidates = await ProjectRecovery.scan();
    expect(candidates, hasLength(1));
    expect(candidates.single.name, 'Delta');
    expect(candidates.single.unsavedWindow.inSeconds, lessThanOrEqualTo(30));

    final restored = await ProjectRecovery.restore(file.path);
    expect(restored.clips.single.start, Rt.fromSeconds(7));
    // Restoring consumes the sidecar, so the prompt does not come back.
    expect(await ProjectRecovery.scan(), isEmpty);
  });

  test('discarding the autosave keeps what was on disk', () async {
    final doc = project('Epsilon');
    final file = await ProjectRepository.projectFile(doc.name);
    await ProjectRepository.save(doc, path: file.path);

    doc.clips.single.start = Rt.fromSeconds(9);
    await ProjectRepository.writeAtomic(
      ProjectRepository.autosaveFor(file.path),
      doc.encode(touchModified: false),
    );

    final kept = await ProjectRecovery.discard(file.path);
    expect(kept.clips.single.start, Rt.zero());
    expect(ProjectRepository.autosaveFor(file.path).existsSync(), isFalse);
  });

  test('duplicate, rename and delete manage the files on disk (PRJ-2)', () async {
    final doc = project('Zeta');
    final file = await ProjectRepository.projectFile(doc.name);
    await ProjectRepository.save(doc, path: file.path);

    final copy = await ProjectRepository.duplicate(file.path);
    expect(copy.existsSync(), isTrue);
    expect((await ProjectRepository.listProjects()), hasLength(2));

    final renamed = await ProjectRepository.rename(file.path, 'Zeta final');
    expect(renamed.path.endsWith('Zeta final.crazycut'), isTrue);
    expect(File(file.path).existsSync(), isFalse);

    await ProjectRepository.delete(renamed.path);
    expect(renamed.existsSync(), isFalse);
  });

  test('project names are sanitised for the filesystem', () async {
    expect(ProjectRepository.sanitize('a/b:c*d'), 'a_b_c_d');
    expect(ProjectRepository.sanitize('   '), 'Untitled');
    expect(ProjectRepository.sanitize('x' * 200).length, 120);
  });
}
