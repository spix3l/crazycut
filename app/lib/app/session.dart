import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/state/editor_controller.dart';
import 'package:crazycut_app/state/proxy_service.dart';
import 'package:crazycut_app/state/sandbox_access.dart';

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
    final doc = ProjectRepository.load(projectPath);
    await open(doc, projectPath);
    return doc;
  }

  /// Call right after the user picks a project file, so the grant the
  /// picker just gave survives the next launch. Note this is only a *file*
  /// grant: saving additionally needs the enclosing folder, which the user
  /// has to hand over separately (see [SandboxAccess]).
  Future<void> rememberProjectLocation(String projectPath) async {
    await SandboxAccess.instance.remember(projectPath);
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

  Future<void> loadRecents() async {
    try {
      final file = await _recentsFile();
      if (!file.existsSync()) return;
      final stored =
          (jsonDecode(await file.readAsString()) as List<dynamic>).cast<String>();
      // Grants were reopened at startup, so an unreachable entry here really
      // is gone rather than merely un-granted.
      final live = stored.where((p) => File(p).existsSync()).toList();
      recents
        ..clear()
        ..addAll(live);
      // A project that went away behind our back — trashed in Finder, on a
      // volume that is no longer mounted — leaves its entry behind. Drop it
      // from the file as well, or it outlives the project forever.
      if (live.length != stored.length) await _writeRecents();
    } on Object {
      // A broken recents file is not worth surfacing.
    }
  }

  /// Drops a project the user deleted (PRJ-2), so it does not come back as a
  /// recent entry pointing at nothing.
  Future<void> forgetRecent(String projectPath) async {
    if (!recents.remove(projectPath)) return;
    await SandboxAccess.instance.forget(projectPath);
    await _writeRecents();
  }

  /// Keeps the entry — and the open project's path — with the file after a
  /// rename, instead of leaving a dangling path to be pruned later.
  Future<void> noteRenamed(String from, String to) async {
    if (from == to) return;
    if (path == from) path = to;
    await SandboxAccess.instance.forget(from);
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
