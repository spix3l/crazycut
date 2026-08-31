import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/app/dependencies.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/project/infrastructure/repository.dart';
import '../support/temp_dir.dart';

void main() {
  late Directory root;
  final session = AppDependencies.production().session;

  Future<File> recentsFile() async =>
      File('${(await ProjectRepository.projectsDir()).path}/.recents.json');

  Future<List<String>> storedRecents() async {
    final file = await recentsFile();
    if (!file.existsSync()) return const [];
    return (jsonDecode(file.readAsStringSync()) as List<dynamic>)
        .cast<String>();
  }

  Future<File> seedProject(String name) async {
    final doc = ProjectDoc.empty(name);
    final file = await ProjectRepository.projectFile(name);
    await ProjectRepository.save(doc, path: file.path);
    return file;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('cc_recents');
    ProjectRepository.rootOverride = root;
    session.recents.clear();
  });

  tearDown(() {
    ProjectRepository.rootOverride = null;
    deleteTempDir(root);
  });

  test('deleting a project drops its recent entry from disk', () async {
    final kept = await seedProject('Kept');
    final doomed = await seedProject('Doomed');
    await (await recentsFile()).writeAsString(
      jsonEncode([doomed.path, kept.path]),
    );
    await session.loadRecents();

    await ProjectRepository.delete(doomed.path);
    await session.forgetRecent(doomed.path);

    expect(session.recents, [kept.path]);
    expect(await storedRecents(), [kept.path]);
  });

  test('a project that vanished behind our back is pruned on load', () async {
    final kept = await seedProject('Kept');
    await (await recentsFile()).writeAsString(
      jsonEncode(['${root.path}/Gone.crazycut', kept.path]),
    );

    await session.loadRecents();

    expect(session.recents, [kept.path]);
    expect(await storedRecents(), [kept.path]);
  });

  test('renaming a project moves its recent entry with the file', () async {
    final original = await seedProject('Before');
    await (await recentsFile()).writeAsString(jsonEncode([original.path]));
    await session.loadRecents();

    final renamed = await ProjectRepository.rename(original.path, 'After');
    await session.noteRenamed(original.path, renamed.path);

    expect(session.recents, [renamed.path]);
    expect(await storedRecents(), [renamed.path]);
  });
}
