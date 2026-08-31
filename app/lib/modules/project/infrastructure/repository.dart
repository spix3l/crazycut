import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:crazycut_app/modules/project/domain/project.dart';

/// Where projects, autosaves and backups live (`02-data-model.md` §8).
class ProjectRepository {
  static Directory? _override;

  /// Tests point this at a temp dir.
  static set rootOverride(Directory? dir) => _override = dir;

  static Future<Directory> projectsDir() async {
    final root = _override ?? await _defaultRoot();
    if (!root.existsSync()) root.createSync(recursive: true);
    return root;
  }

  static Future<Directory> _defaultRoot() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}${Platform.pathSeparator}CrazyCut');
    } on Object {
      // macOS TCC can deny Documents; fall back rather than fail to launch.
      final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
      return Directory('$home/Library/CrazyCut/Projects');
    }
  }

  static Future<Directory> backupsDir() async {
    final dir = Directory('${(await projectsDir()).path}${Platform.pathSeparator}backups');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<File> projectFile(String name) async {
    final dir = await projectsDir();
    return File('${dir.path}${Platform.pathSeparator}${sanitize(name)}.crazycut');
  }

  static String sanitize(String name) {
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safe.isEmpty) return 'Untitled';
    return safe.length <= 120 ? safe : safe.substring(0, 120);
  }

  static File autosaveFor(String projectPath) => File('$projectPath.autosave');

  static Future<List<(File, ProjectDoc)>> listProjects() async {
    final dir = await projectsDir();
    if (!dir.existsSync()) return [];
    final files =
        dir.listSync().whereType<File>().where((f) => f.path.endsWith('.crazycut')).toList()
          ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    final result = <(File, ProjectDoc)>[];
    for (final f in files) {
      try {
        result.add((f, ProjectDoc.decode(f.readAsStringSync())));
      } catch (_) {
        // Unreadable projects are skipped here; the recovery flow handles them.
      }
    }
    return result;
  }

  /// Atomic write: temp file, flush, rename (§8).
  static Future<void> writeAtomic(File file, String contents) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(file.path);
  }

  static Future<void> save(ProjectDoc doc, {String? path}) async {
    final file = path != null ? File(path) : await projectFile(doc.name);
    await writeAtomic(file, doc.encode());
    // A completed save makes any pending autosave stale.
    final autosave = autosaveFor(file.path);
    if (autosave.existsSync()) await autosave.delete();
  }

  static ProjectDoc load(String path, {RepairReport? report}) =>
      ProjectDoc.decode(File(path).readAsStringSync(), report: report);

  /// PRJ-9 "Save a copy…" — an independent snapshot, new ids.
  static Future<File> saveCopy(ProjectDoc doc, String destinationPath) async {
    final file = File(destinationPath);
    await writeAtomic(file, doc.duplicate(name: doc.name).encode());
    return file;
  }

  /// PRJ-2 duplicate: independent copy next to the original.
  static Future<File> duplicate(String path) async {
    final source = load(path);
    final copy = source.duplicate();
    final file = await projectFile(copy.name);
    await writeAtomic(file, copy.encode());
    return file;
  }

  static Future<File> rename(String path, String newName) async {
    final doc = load(path);
    doc.name = newName;
    final target = await projectFile(newName);
    await writeAtomic(target, doc.encode());
    final old = File(path);
    if (old.existsSync() && old.path != target.path) await old.delete();
    return target;
  }

  /// PRJ-2 delete: the project file and its backups only, never media.
  static Future<void> delete(String path) async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
    final autosave = autosaveFor(path);
    if (autosave.existsSync()) await autosave.delete();
    for (final backup in await backupsFor(path)) {
      await backup.delete();
    }
  }

  static String _backupPrefix(String projectPath) =>
      projectPath.split(Platform.pathSeparator).last.replaceAll('.crazycut', '');

  static Future<List<File>> backupsFor(String projectPath) async {
    final dir = await backupsDir();
    final prefix = '${_backupPrefix(projectPath)}-';
    if (!dir.existsSync()) return [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.split(Platform.pathSeparator).last.startsWith(prefix))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  }

  /// PRJ-7 backup ring: timestamped copy, oldest pruned past [keep].
  static Future<File> writeBackup(ProjectDoc doc, String projectPath,
      {int keep = 20}) async {
    final dir = await backupsDir();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File(
      '${dir.path}${Platform.pathSeparator}${_backupPrefix(projectPath)}-$stamp.crazycut',
    );
    await writeAtomic(file, doc.encode(touchModified: false));
    final existing = await backupsFor(projectPath);
    for (final old in existing.skip(keep)) {
      await old.delete();
    }
    return file;
  }
}
