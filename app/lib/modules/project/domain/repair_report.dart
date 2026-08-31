part of 'project.dart';

/// What the loader had to repair to satisfy §10 invariants.
class RepairReport {
  final List<String> issues = [];
  bool get isEmpty => issues.isEmpty;
}
