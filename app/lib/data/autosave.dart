import 'dart:async';
import 'dart:io';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';

enum SaveState { saved, dirty, saving, failed }

/// Autosave, hard-save and backup cadence for one open project
/// (PRJ-6/7, `02-data-model.md` §8).
///
/// Cadence: 2 s debounce after each committed change writes the sidecar
/// autosave; a hard save of the project file runs every 30 s while dirty; a
/// timestamped backup lands every 5 minutes while dirty. A clean save removes
/// the sidecar, which is exactly the signal crash recovery looks for.
class ProjectAutosave {
  ProjectAutosave(
    this.doc, {
    required this.path,
    this.onStateChanged,
    this.debounce = const Duration(seconds: 2),
    this.hardSaveInterval = const Duration(seconds: 30),
    this.backupInterval = const Duration(minutes: 5),
    this.backupsToKeep = 20,
  });

  final ProjectDoc doc;
  String path;
  final void Function(SaveState state)? onStateChanged;
  final Duration debounce;
  final Duration hardSaveInterval;
  final Duration backupInterval;
  final int backupsToKeep;

  Timer? _debounceTimer;
  Timer? _hardTimer;
  Timer? _backupTimer;
  bool _dirty = false;
  bool _writing = false;
  SaveState _state = SaveState.saved;
  DateTime? lastSavedAt;

  SaveState get state => _state;
  bool get isDirty => _dirty;

  void _setState(SaveState value) {
    if (_state == value) return;
    _state = value;
    onStateChanged?.call(value);
  }

  void markDirty() {
    _dirty = true;
    _setState(SaveState.dirty);
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, writeAutosave);
    _hardTimer ??= Timer.periodic(hardSaveInterval, (_) {
      if (_dirty) unawaited(saveNow());
    });
    _backupTimer ??= Timer.periodic(backupInterval, (_) {
      if (_dirty) unawaited(writeBackup());
    });
  }

  /// Sidecar write — cheap, frequent, never touches the project file.
  Future<void> writeAutosave() async {
    if (!_dirty || _writing) return;
    _writing = true;
    _setState(SaveState.saving);
    try {
      await ProjectRepository.writeAtomic(
        ProjectRepository.autosaveFor(path),
        doc.encode(touchModified: false),
      );
      _setState(SaveState.dirty);
    } on Object {
      _setState(SaveState.failed);
    } finally {
      _writing = false;
    }
  }

  /// Full save of the project file; clears the dirty flag and the sidecar.
  Future<void> saveNow() async {
    if (_writing) return;
    _writing = true;
    _setState(SaveState.saving);
    try {
      await ProjectRepository.save(doc, path: path);
      _dirty = false;
      lastSavedAt = DateTime.now();
      _setState(SaveState.saved);
    } on Object {
      _setState(SaveState.failed);
    } finally {
      _writing = false;
    }
  }

  Future<void> writeBackup() async {
    try {
      await ProjectRepository.writeBackup(doc, path, keep: backupsToKeep);
    } on Object {
      // Backups are best-effort; never surface as an editing failure.
    }
  }

  Future<void> close() async {
    _debounceTimer?.cancel();
    _hardTimer?.cancel();
    _backupTimer?.cancel();
    _debounceTimer = null;
    _hardTimer = null;
    _backupTimer = null;
    if (_dirty) await saveNow();
  }

  void dispose() {
    _debounceTimer?.cancel();
    _hardTimer?.cancel();
    _backupTimer?.cancel();
  }
}

/// A project whose sidecar autosave outlived its project file — i.e. the app
/// went away without a clean save (PRJ-8).
class RecoveryCandidate {
  RecoveryCandidate({
    required this.projectPath,
    required this.name,
    required this.autosaveModified,
    required this.projectModified,
  });

  final String projectPath;
  final String name;
  final DateTime autosaveModified;
  final DateTime projectModified;

  Duration get unsavedWindow => autosaveModified.difference(projectModified);
}

class ProjectRecovery {
  /// Looks for autosaves newer than their project file.
  static Future<List<RecoveryCandidate>> scan() async {
    final dir = await ProjectRepository.projectsDir();
    if (!dir.existsSync()) return const [];
    final candidates = <RecoveryCandidate>[];
    for (final file in dir.listSync().whereType<File>()) {
      if (!file.path.endsWith('.crazycut.autosave')) continue;
      final projectPath = file.path.replaceAll('.autosave', '');
      final project = File(projectPath);
      if (!project.existsSync()) continue;
      final autosaveTime = file.statSync().modified;
      final projectTime = project.statSync().modified;
      if (!autosaveTime.isAfter(projectTime)) continue;
      if (file.readAsStringSync() == project.readAsStringSync()) continue;
      String name = projectPath.split(Platform.pathSeparator).last;
      try {
        name = ProjectDoc.decode(file.readAsStringSync()).name;
      } on Object {
        // Keep the filename if the autosave is unreadable.
      }
      candidates.add(RecoveryCandidate(
        projectPath: projectPath,
        name: name,
        autosaveModified: autosaveTime,
        projectModified: projectTime,
      ));
    }
    return candidates;
  }

  /// Promotes the autosave to be the project file.
  static Future<ProjectDoc> restore(String projectPath) async {
    final autosave = ProjectRepository.autosaveFor(projectPath);
    final doc = ProjectDoc.decode(autosave.readAsStringSync());
    await ProjectRepository.save(doc, path: projectPath);
    return doc;
  }

  /// Keeps what is on disk and drops the sidecar.
  static Future<ProjectDoc> discard(String projectPath) async {
    final autosave = ProjectRepository.autosaveFor(projectPath);
    if (autosave.existsSync()) await autosave.delete();
    return ProjectRepository.load(projectPath);
  }

  static Future<ProjectDoc> openBackup(String backupPath, String projectPath) async {
    final doc = ProjectDoc.decode(File(backupPath).readAsStringSync());
    await ProjectRepository.save(doc, path: projectPath);
    final autosave = ProjectRepository.autosaveFor(projectPath);
    if (autosave.existsSync()) await autosave.delete();
    return doc;
  }
}
