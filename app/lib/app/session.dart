import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/state/editor_controller.dart';

/// App-scoped editing session: which project is open and its controller.
/// Routes read this instead of passing models through constructors, so the
/// browser can hand off a project with a plain navigation.
class AppSession {
  AppSession._();

  static final AppSession instance = AppSession._();

  ProjectDoc? project;
  EditorController? _controller;

  EditorController get editor {
    final p = project;
    if (p == null) {
      throw StateError('No project open');
    }
    return _controller ??= EditorController(p);
  }

  bool get hasProject => project != null;

  void open(ProjectDoc doc) {
    _controller = null;
    project = doc;
    ProjectRepository.save(doc);
  }

  Future<ProjectDoc> createNew({
    required String name,
    required int width,
    required int height,
    required double fps,
  }) async {
    final doc = ProjectDoc.empty(
      name.isEmpty ? 'Untitled' : name,
      width: width,
      height: height,
      fps: fps,
    );
    await ProjectRepository.save(doc);
    open(doc);
    return doc;
  }

  void close() {
    _controller?.dispose();
    _controller = null;
    project = null;
  }
}
