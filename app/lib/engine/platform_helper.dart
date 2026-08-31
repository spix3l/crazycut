part of 'engine.dart';

class PlatformHelper {
  /// Where the engine library lives, most specific first: inside an installed
  /// app bundle, then the development build tree.
  static List<String> engineLibCandidates() {
    return [
      ..._bundled(['libcrazycut.dylib', 'crazycut.dll']),
      '../engine/build-release/libcrazycut.dylib',
      '../../engine/build-release/libcrazycut.dylib',
      '../engine/build/libcrazycut.dylib',
      '../../engine/build/libcrazycut.dylib',
      '../engine/build/Debug/crazycut.dll',
      '../engine/build/Release/crazycut.dll',
    ];
  }

  /// Paths beside the running executable. A packaged app ships the engine and
  /// the worker next to itself; a `flutter run` tree does not, and falls
  /// through to the build directory below.
  static List<String> _bundled(List<String> names) {
    final executable = File(Platform.resolvedExecutable);
    final dir = executable.parent;                    // …/Contents/MacOS
    final roots = <Directory>[
      dir,
      Directory('${dir.parent.path}/Frameworks'),     // …/Contents/Frameworks
      Directory('${dir.parent.path}/Resources'),      // …/Contents/Resources
    ];
    return [
      for (final root in roots)
        for (final name in names) '${root.path}${Platform.pathSeparator}$name',
    ];
  }

  /// First worker binary that exists, or null when the engine build is
  /// missing (proxy and export features then report unavailable).
  static String? workerBinary() {
    for (final candidate in workerBinCandidates()) {
      if (candidate.isEmpty) continue;
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static List<String> workerBinCandidates() {
    const defined = String.fromEnvironment('CRAZYCUT_WORKER_BIN');
    if (defined.isNotEmpty) return [defined];
    return [
      ..._bundled(['crazycut_worker', 'crazycut_worker.exe']),
      '../engine/build-release/crazycut_worker',
      '../../engine/build-release/crazycut_worker',
      '../engine/build/crazycut_worker',
      '../../engine/build/crazycut_worker',
      '../engine/build/Debug/crazycut_worker.exe',
      '../engine/build/Release/crazycut_worker.exe',
    ];
  }
}
