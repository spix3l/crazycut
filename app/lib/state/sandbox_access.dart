import 'dart:convert';
import 'dart:io';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/state/security_scoped_bookmarks.dart';

/// Persistent sandbox grants (macOS App Sandbox).
///
/// The sandbox only lets CrazyCut reach a path the user picked, and only for
/// the run they picked it in. A security-scoped bookmark re-grants that access
/// on a later launch. Two scopes matter, and conflating them is what makes a
/// project look broken after a relaunch:
///
///  * a **file** bookmark grants exactly that file. It is all a file picker
///    can give us — the sandbox never granted the enclosing folder, so a
///    bookmark over the parent would simply fail to be issued. Enough to keep
///    reading an imported clip, and taken silently at import.
///  * a **folder** bookmark grants everything inside, including the right to
///    *create* files there. Only a folder grant can fix saving, because
///    [ProjectRepository.writeAtomic] writes a sibling `.tmp` and autosave a
///    sibling `.autosave`; creating a new file needs the folder, not the file.
///    It requires the user to pick the folder itself.
///
/// Grants are machine-specific, so they live app-wide in the container and
/// never travel inside a `.crazycut` document.
class SandboxAccess {
  SandboxAccess._();

  static final SandboxAccess instance = SandboxAccess._();

  Map<String, String>? _bookmarks;

  /// Only meaningful where the sandbox is; elsewhere every path is already
  /// reachable and the whole mechanism stays out of the way.
  static bool get isEnforced => Platform.isMacOS;

  static String folderOf(String path) => File(path).parent.path;

  /// Resolves every stored grant, which is what actually reopens access for
  /// this process. Must run before anything probes the disk, or the first
  /// existence check of the run decides a reachable file is missing.
  Future<void> restoreAll() async {
    if (!isEnforced) return;
    final stored = await _read();
    var changed = false;
    for (final entry in stored.entries.toList()) {
      final resolved = await SecurityScopedBookmarks.resolve(entry.value);
      if (resolved == null) continue;
      // A path that moved keeps its grant, under its new location.
      if (resolved.path != entry.key) {
        stored.remove(entry.key);
        changed = true;
      }
      stored[resolved.path] = resolved.refreshedBookmark ?? entry.value;
      if (resolved.refreshedBookmark != null) changed = true;
    }
    _bookmarks = stored;
    if (changed) await _write(stored);
  }

  /// Silently records a grant for a path the user just picked. Safe to call
  /// for any pick; it simply yields nothing when the OS declines.
  Future<bool> remember(String path) async {
    if (!isEnforced) return true;
    final bookmark = await SecurityScopedBookmarks.create(path);
    if (bookmark == null) return false;
    final stored = await _read();
    stored[path] = bookmark;
    _bookmarks = stored;
    await _write(stored);
    return true;
  }

  Future<void> forget(String path) async {
    if (!isEnforced) return;
    final stored = await _read();
    if (stored.remove(path) == null) return;
    _bookmarks = stored;
    await _write(stored);
  }

  /// True when [folder]'s contents can be listed right now. Probes rather
  /// than trusting a stored grant, because a bookmark can resolve and still
  /// leave the folder unreachable if its volume went away.
  bool canRead(String folder) {
    try {
      Directory(folder).listSync(followLinks: false).take(1).toList();
      return true;
    } on Object {
      return false;
    }
  }

  /// True when a *new* file can be created in [folder] — the permission a
  /// project save actually needs, and the one a file grant does not give.
  bool canWrite(String folder) {
    final probe = File('$folder${Platform.pathSeparator}.crazycut-access-probe');
    try {
      probe.writeAsStringSync('', flush: true);
      return true;
    } on Object {
      return false;
    } finally {
      try {
        if (probe.existsSync()) probe.deleteSync();
      } on Object {
        // Leaving the probe behind is harmless next to failing the check.
      }
    }
  }

  /// The folders [doc] needs, and whether each must be writable. The
  /// project's own folder is written to; media folders are only read.
  static Map<String, bool> requiredFolders(ProjectDoc doc, String projectPath) {
    final folders = <String, bool>{folderOf(projectPath): true};
    for (final asset in doc.media) {
      if (asset.isRemote || asset.path.isEmpty) continue;
      folders.putIfAbsent(folderOf(asset.path), () => false);
    }
    return folders;
  }

  /// Which folders are still out of reach, writable ones first so the most
  /// damaging gap is addressed first, then stably ordered so the prompt does
  /// not reshuffle between opens.
  List<FolderRequest> blocked(ProjectDoc doc, String projectPath) {
    if (!isEnforced) return const [];
    final requests = <FolderRequest>[];
    requiredFolders(doc, projectPath).forEach((folder, needsWrite) {
      // A file grant can make individual clips readable while the folder
      // itself stays closed; only ask when files are actually unreachable.
      final satisfied =
          needsWrite
              ? canWrite(folder)
              : canRead(folder) || _filesReadable(doc, folder);
      if (!satisfied) {
        requests.add(FolderRequest(folder: folder, needsWrite: needsWrite));
      }
    });
    requests.sort((a, b) {
      if (a.needsWrite != b.needsWrite) return a.needsWrite ? -1 : 1;
      return a.folder.compareTo(b.folder);
    });
    return requests;
  }

  /// True when every asset [doc] keeps in [folder] is individually reachable,
  /// which is what per-file grants from an import produce.
  bool _filesReadable(ProjectDoc doc, String folder) {
    final assets = doc.media.where(
      (a) => !a.isRemote && a.path.isNotEmpty && folderOf(a.path) == folder,
    );
    if (assets.isEmpty) return true;
    return assets.every((a) => File(a.path).existsSync());
  }

  // --- Storage --------------------------------------------------------------
  //
  // Kept in the app's own container, which never needs a grant of its own.

  Future<File> _file() async {
    final dir = await ProjectRepository.projectsDir();
    return File('${dir.path}${Platform.pathSeparator}.sandbox-access.json');
  }

  Future<Map<String, String>> _read() async {
    final cached = _bookmarks;
    if (cached != null) return cached;
    try {
      final file = await _file();
      if (!file.existsSync()) return {};
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return decoded.cast<String, String>();
    } on Object {
      return {};
    }
  }

  Future<void> _write(Map<String, String> bookmarks) async {
    try {
      await (await _file()).writeAsString(jsonEncode(bookmarks));
    } on Object {
      // Best effort: a lost grant costs one re-pick, not data.
    }
  }
}

/// One folder the user has to hand back, and why.
class FolderRequest {
  const FolderRequest({required this.folder, required this.needsWrite});

  final String folder;
  final bool needsWrite;

  String get name {
    final parts = folder.split(Platform.pathSeparator).where((p) => p.isNotEmpty);
    return parts.isEmpty ? folder : parts.last;
  }

  String get reason =>
      needsWrite ? 'to save the project here' : 'to load media from here';
}
