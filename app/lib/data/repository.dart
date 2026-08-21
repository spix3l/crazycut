import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:crazycut_app/data/project.dart';

class ProjectRepository {
  static Future<Directory> projectsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}CrazyCut');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<File> projectFile(String name) async {
    final dir = await projectsDir();
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return File('${dir.path}${Platform.pathSeparator}$safe.crazycut');
  }

  static Future<List<(File, ProjectDoc)>> listProjects() async {
    final dir = await projectsDir();
    if (!dir.existsSync()) return [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.crazycut'))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    final result = <(File, ProjectDoc)>[];
    for (final f in files) {
      try {
        result.add((f, ProjectDoc.decode(f.readAsStringSync())));
      } catch (_) {}
    }
    return result;
  }

  static Future<void> save(ProjectDoc doc, {String? path}) async {
    final file =
        path != null ? File(path) : await projectFile(doc.name);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(doc.encode(), flush: true);
    await tmp.rename(file.path);
  }

  static ProjectDoc load(String path) =>
      ProjectDoc.decode(File(path).readAsStringSync());
}
