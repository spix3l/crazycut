part of 'autosave.dart';

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
