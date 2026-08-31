part of 'autosave.dart';

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
