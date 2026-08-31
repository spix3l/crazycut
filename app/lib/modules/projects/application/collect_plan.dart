part of 'project_tools.dart';

/// What "Collect media to project folder" would copy, so the user sees the
/// size before committing (PRJ-14).
class CollectPlan {
  const CollectPlan({
    required this.assets,
    required this.totalBytes,
    required this.alreadyLocal,
    required this.missing,
    this.remote = 0,
  });

  final List<MediaAsset> assets;
  final int totalBytes;

  /// Assets already inside the project's Media folder — nothing to copy.
  final int alreadyLocal;
  final List<MediaAsset> missing;
  final int remote;

  bool get isEmpty => assets.isEmpty;

  String get sizeLabel => _formatBytes(totalBytes);

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}
