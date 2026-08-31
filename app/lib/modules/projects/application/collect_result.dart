part of 'project_tools.dart';

class CollectResult {
  const CollectResult({
    required this.copied,
    required this.skipped,
    this.error,
  });

  final int copied;
  final int skipped;
  final String? error;
}
