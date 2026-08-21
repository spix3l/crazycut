import 'dart:convert';
import 'dart:io';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/state/editor_controller.dart';
import 'package:crazycut_app/state/proxy_service.dart';

/// App-scoped editing session: which project is open, its controller, and the
/// recent-projects list (PRJ-4). Routes read this instead of threading models
/// through constructors, so the browser hands off with a plain navigation.
class AppSession {
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
  }

  Future<ProjectDoc> openPath(String projectPath) async {
    final doc = ProjectRepository.load(projectPath);
    await open(doc, projectPath);
    return doc;
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
      final list = (jsonDecode(await file.readAsString()) as List<dynamic>)
          .cast<String>()
          .where((p) => File(p).existsSync());
      recents
        ..clear()
        ..addAll(list);
    } on Object {
      // A broken recents file is not worth surfacing.
    }
  }

  Future<void> _rememberRecent(String projectPath) async {
    recents.remove(projectPath);
    recents.insert(0, projectPath);
    if (recents.length > maxRecents) recents.removeRange(maxRecents, recents.length);
    try {
      await (await _recentsFile()).writeAsString(jsonEncode(recents));
    } on Object {
      // Best effort.
    }
  }
}
