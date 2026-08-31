part of 'autosave.dart';

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
