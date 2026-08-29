import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/state/editor_controller.dart';
import 'package:crazycut_app/state/proxy_service.dart';
import 'package:crazycut_app/state/security_scoped_bookmarks.dart';

/// App-scoped editing session: which project is open, its controller, and the
/// recent-projects list (PRJ-4). Routes read this instead of threading models
/// through constructors, so the browser hands off with a plain navigation.
///
/// Opening and closing a project notifies listeners: navigation alone is not a
/// reliable signal for screens underneath the editor, because a route that is
/// replaced rather than popped never completes its push future.
class AppSession extends ChangeNotifier {
  AppSession._();

  static final AppSession instance = AppSession._();

  /// Shared across projects so a queued proxy survives closing the editor.
  final ProxyService proxies = ProxyService();

  ProjectDoc? project;
  String? path;
  EditorController? _controller;

  final List<String> recents = [];
  static const int maxRecents = 10;

  bool get hasProject => project != null && _controller != null;

  EditorController get editor {
    final controller = _controller;
    if (controller == null) throw StateError('No project open');
    return controller;
  }

  Future<void> open(ProjectDoc doc, String projectPath) async {
    await close();
    project = doc;
    path = projectPath;
    _controller = EditorController(doc, path: projectPath, proxies: proxies);
    await _rememberRecent(projectPath);
    notifyListeners();
  }

  Future<ProjectDoc> openPath(String projectPath) async {
    final resolved = await _restoreProjectAccess(projectPath);
    final doc = ProjectRepository.load(resolved);
    await open(doc, resolved);
    return doc;
  }

  /// Call right after the user picks a project file outside CrazyCut's own
  /// project folder (open, "save a copy") so it stays reachable across
  /// relaunches: a `.crazycut` there only lives inside the app's sandboxed
  /// container when it was created with "New Project", and the sandbox only
  /// grants access to an externally-picked path for the run it was picked in.
  Future<void> rememberProjectLocation(String projectPath) async {
    final bookmark = await SecurityScopedBookmarks.create(projectPath);
    if (bookmark == null) return;
    final bookmarks = await _readBookmarks();
    bookmarks[projectPath] = bookmark;
    await _writeBookmarks(bookmarks);
  }

  /// Resolves a stored bookmark for [projectPath], if there is one, so a
  /// lapsed sandbox grant doesn't make an untouched project unreadable.
  /// Returns the path to actually open — the bookmark's own if it moved.
  Future<String> _restoreProjectAccess(String projectPath) async {
    final bookmarks = await _readBookmarks();
    final bookmark = bookmarks[projectPath];
    if (bookmark == null) return projectPath;
    final resolved = await SecurityScopedBookmarks.resolve(bookmark);
    if (resolved == null) return projectPath;
    if (resolved.refreshedBookmark != null || resolved.path != projectPath) {
      bookmarks.remove(projectPath);
      bookmarks[resolved.path] = resolved.refreshedBookmark ?? bookmark;
      await _writeBookmarks(bookmarks);
    }
    return resolved.path;
  }

  Future<ProjectDoc> createNew({
    required String name,
    required int width,
    required int height,
    required double fps,
  }) async {
    final doc = ProjectDoc.empty(
      name.trim().isEmpty ? 'Untitled' : name.trim(),
      width: width,
      height: height,
      fps: fps,
    );
    final file = await ProjectRepository.projectFile(doc.name);
    await ProjectRepository.save(doc, path: file.path);
    await open(doc, file.path);
    return doc;
  }

  /// Saves and tears down the open project. Safe to call when none is open.
  Future<void> close() async {
    final controller = _controller;
    _controller = null;
    project = null;
    path = null;
    if (controller != null) {
      await controller.close();
      controller.dispose();
      notifyListeners();
    }
  }

  // --- Recents (PRJ-4) ------------------------------------------------------

  Future<File> _recentsFile() async {
    final dir = await ProjectRepository.projectsDir();
    return File('${dir.path}${Platform.pathSeparator}.recents.json');
  }

  // --- Project-path bookmarks -----------------------------------------------
  //
  // Keyed by absolute project path, alongside the recents file so both are
  // always inside the app's own sandboxed container and never need a
  // bookmark themselves.

  Future<File> _projectBookmarksFile() async {
    final dir = await ProjectRepository.projectsDir();
    return File('${dir.path}${Platform.pathSeparator}.bookmarks.json');
  }

  Future<Map<String, String>> _readBookmarks() async {
    try {
      final file = await _projectBookmarksFile();
      if (!file.existsSync()) return {};
      final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return decoded.cast<String, String>();
    } on Object {
      return {};
    }
  }

  Future<void> _writeBookmarks(Map<String, String> bookmarks) async {
    try {
      await (await _projectBookmarksFile()).writeAsString(jsonEncode(bookmarks));
    } on Object {
      // Best effort, same as the recents file.
    }
  }

  Future<void> _forgetProjectLocation(String projectPath) async {
    final bookmarks = await _readBookmarks();
    if (bookmarks.remove(projectPath) == null) return;
    await _writeBookmarks(bookmarks);
  }

  Future<void> loadRecents() async {
    try {
      final file = await _recentsFile();
      if (!file.existsSync()) return;
      final stored =
          (jsonDecode(await file.readAsString()) as List<dynamic>).cast<String>();
      // A bookmarked entry may only look gone because its sandbox grant
      // lapsed over a relaunch; re-resolving it before the existence check
      // is what keeps that project from being pruned out from under the user.
      final live = <String>[];
      for (final storedPath in stored) {
        final path = await _restoreProjectAccess(storedPath);
        if (File(path).existsSync()) live.add(path);
      }
      recents
        ..clear()
        ..addAll(live);
      // A project that went away behind our back — trashed in Finder, on a
      // volume that is no longer mounted — leaves its entry behind. Drop it
      // from the file as well, or it outlives the project forever.
      if (!listEquals(live, stored)) await _writeRecents();
    } on Object {
      // A broken recents file is not worth surfacing.
    }
  }

  /// Drops a project the user deleted (PRJ-2), so it does not come back as a
  /// recent entry pointing at nothing.
  Future<void> forgetRecent(String projectPath) async {
    if (!recents.remove(projectPath)) return;
    await _forgetProjectLocation(projectPath);
    await _writeRecents();
  }

  /// Keeps the entry — and the open project's path — with the file after a
  /// rename, instead of leaving a dangling path to be pruned later.
  Future<void> noteRenamed(String from, String to) async {
    if (from == to) return;
    if (path == from) path = to;
    await _forgetProjectLocation(from);
    if (!recents.contains(from)) return;
    recents.removeWhere((p) => p == to);
    recents[recents.indexOf(from)] = to;
    await _writeRecents();
  }

  Future<void> _rememberRecent(String projectPath) async {
    recents.remove(projectPath);
    recents.insert(0, projectPath);
    if (recents.length > maxRecents) recents.removeRange(maxRecents, recents.length);
    await _writeRecents();
  }

  Future<void> _writeRecents() async {
    try {
      await (await _recentsFile()).writeAsString(jsonEncode(recents));
    } on Object {
      // Best effort.
    }
  }
}
