part of 'commands.dart';

/// Before/after JSON for one entity. A null side means "did not exist".
class EntityDelta {
  const EntityDelta(this.before, this.after);

  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;

  bool get isNoop {
    if (before == null && after == null) return true;
    if (before == null || after == null) return false;
    return jsonEncode(before) == jsonEncode(after);
  }

  int get sizeBytes =>
      (before == null ? 0 : jsonEncode(before).length) +
      (after == null ? 0 : jsonEncode(after).length);
}
