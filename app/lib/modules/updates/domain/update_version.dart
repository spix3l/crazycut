// Strict semantic version handling for the updater.
//
// Only stable `X.Y.Z` (with an optional single leading `v`) is accepted.
// Anything else (prereleases, build metadata, partial versions) parses to
// null and the update check treats it as "no update". This is deliberate:
// the updater must fail closed rather than guess at ordering.
class UpdateVersion implements Comparable<UpdateVersion> {
  const UpdateVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static final RegExp _full = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$');
  static final RegExp _stableTag = RegExp(r'^v\d+\.\d+\.\d+$');

  /// True for release tags the updater trusts (e.g. `v0.3.0`).
  static bool isStableTag(String tag) => _stableTag.hasMatch(tag);

  /// Parses `0.3.0` or `v0.3.0`. Returns null for anything else, including
  /// prerelease suffixes such as `v0.3.0-rc.1`.
  static UpdateVersion? tryParse(String input) {
    final match = _full.matchAsPrefix(input.trim());
    if (match == null) return null;
    // Reject inputs with trailing content (e.g. "-rc.1", "+build").
    if (match.end != input.trim().length) return null;
    try {
      return UpdateVersion(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
      );
    } on FormatException {
      return null;
    }
  }

  @override
  int compareTo(UpdateVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(UpdateVersion other) => compareTo(other) > 0;
  bool operator <(UpdateVersion other) => compareTo(other) < 0;
  bool operator >=(UpdateVersion other) => compareTo(other) >= 0;
  bool operator <=(UpdateVersion other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is UpdateVersion &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}
