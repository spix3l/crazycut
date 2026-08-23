import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/data/template.dart';

/// The on-disk template library (TPL-1/2/3).
///
/// One `.cctemplate` file per template under `<CrazyCut>/Templates`, shared by
/// every project. The library keeps the parsed list in memory and notifies on
/// change so panels can bind to it directly; unreadable files are counted, not
/// thrown, because a bad file must never take the list down with it.
class TemplateLibrary extends ChangeNotifier {
  TemplateLibrary._();

  static final TemplateLibrary instance = TemplateLibrary._();

  final List<ClipTemplate> _templates = [];
  int _unreadable = 0;
  bool _loaded = false;

  /// Templates, newest first.
  List<ClipTemplate> get templates => List.unmodifiable(_templates);

  /// How many files in the folder failed to parse on the last refresh (TPL-3).
  int get unreadableCount => _unreadable;

  bool get isLoaded => _loaded;

  static Future<Directory> directory() async {
    final root = await ProjectRepository.projectsDir();
    final dir = Directory('${root.path}${Platform.pathSeparator}Templates');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<File> fileFor(ClipTemplate template) async {
    final existing = template.filePath;
    if (existing != null && existing.isNotEmpty) return File(existing);
    final dir = await directory();
    final base = ProjectRepository.sanitize(template.name);
    return File(
      '${dir.path}${Platform.pathSeparator}$base-${template.id}'
      '.$kTemplateExtension',
    );
  }

  /// Re-reads the folder. A folder that cannot be listed (no permission, no
  /// Documents dir) yields an empty library rather than an error.
  Future<void> refresh() async {
    final loaded = <ClipTemplate>[];
    var bad = 0;
    try {
      final dir = await directory();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.$kTemplateExtension'))
          .toList();
      for (final file in files) {
        try {
          loaded.add(
            ClipTemplate.decode(file.readAsStringSync(), filePath: file.path),
          );
        } on Object catch (e) {
          bad++;
          debugPrint('template unreadable ${file.path}: $e');
        }
      }
    } on Object catch (e) {
      debugPrint('template library unavailable: $e');
    }
    loaded.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _templates
      ..clear()
      ..addAll(loaded);
    _unreadable = bad;
    _loaded = true;
    notifyListeners();
  }

  /// Loads once; later callers get the cached list.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await refresh();
  }

  /// Atomic write, same discipline as project saves (TPL-6).
  Future<File> save(ClipTemplate template) async {
    final file = await fileFor(template);
    await ProjectRepository.writeAtomic(file, template.encode());
    template.filePath = file.path;
    final at = _templates.indexWhere((t) => t.id == template.id);
    if (at >= 0) {
      _templates[at] = template;
    } else {
      _templates.insert(0, template);
    }
    notifyListeners();
    return file;
  }

  Future<void> delete(ClipTemplate template) async {
    final path = template.filePath;
    if (path != null) {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    }
    _templates.removeWhere((t) => t.id == template.id);
    notifyListeners();
  }

  Future<ClipTemplate> rename(ClipTemplate template, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == template.name) return template;
    // The file name carries the template name, so a rename moves the file:
    // write the new one first, then drop the old, never the other way round.
    final old = template.filePath;
    template
      ..name = trimmed
      ..filePath = null;
    await save(template);
    if (old != null && old != template.filePath) {
      final file = File(old);
      if (file.existsSync()) await file.delete();
    }
    notifyListeners();
    return template;
  }

  Future<ClipTemplate> duplicate(ClipTemplate template) async {
    final copy = template.copy(
      id:
          '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}'
          '-${template.id}',
      name: '${template.name} copy',
    )..filePath = null;
    await save(copy);
    return copy;
  }

  /// Test seam: point the library at a temp folder and start empty.
  @visibleForTesting
  void resetForTest() {
    _templates.clear();
    _unreadable = 0;
    _loaded = false;
  }
}
