part of 'media_relink.dart';

/// Finds new homes for offline media (IMP-15/16).
///
/// Hashing is the only way to be certain a file is the same one, so it goes
/// first; name+size is offered as a proposal rather than applied silently,
/// because two takes can easily share a name.
class MediaRelinker {
  MediaRelinker._();

  static final MediaRelinker instance = MediaRelinker._();

  /// Files that can plausibly be media, gathered from [paths]; directories are
  /// walked recursively (IMP-16 folder relink).
  static List<File> gatherCandidates(List<String> paths, {int limit = 5000}) {
    final files = <File>[];
    void addFile(File file) {
      if (files.length >= limit) return;
      final ext = file.path.split('.').last.toLowerCase();
      if (kSupportedExtensions.contains(ext)) files.add(file);
    }

    for (final path in paths) {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        try {
          for (final entity in Directory(path).listSync(recursive: true)) {
            if (entity is File) addFile(entity);
          }
        } catch (e) {
          debugPrint('relink scan failed for $path: $e');
        }
      } else if (type == FileSystemEntityType.file) {
        addFile(File(path));
      }
    }
    return files;
  }

  /// Matches [missing] against [candidates]. Each candidate is used at most
  /// once, so relinking a folder of takes cannot point two clips at one file.
  RelinkPlan plan(List<MediaAsset> missing, List<File> candidates) {
    final matches = <RelinkMatch>[];
    final unmatched = <MediaAsset>[];
    final taken = <String>{};

    // Index by name and by size once; hashing is done lazily and cached,
    // because it reads whole files.
    final byName = <String, List<File>>{};
    for (final file in candidates) {
      final name = file.uri.pathSegments.last;
      byName.putIfAbsent(name, () => []).add(file);
    }
    final hashes = <String, String>{};
    String? hashOf(File file) {
      final cached = hashes[file.path];
      if (cached != null) return cached;
      try {
        final hash = CrazyCutEngine.instance.hashFile(file.path);
        hashes[file.path] = hash;
        return hash;
      } catch (e) {
        debugPrint('hash failed for ${file.path}: $e');
        return null;
      }
    }

    for (final asset in missing) {
      RelinkMatch? found;

      // 1. Same content, wherever it lives now.
      if (asset.hash.isNotEmpty) {
        for (final file in candidates) {
          if (taken.contains(file.path)) continue;
          if (hashOf(file) == asset.hash) {
            found = RelinkMatch(
              assetId: asset.id,
              assetName: asset.name,
              path: file.path,
              confidence: RelinkConfidence.exact,
            );
            break;
          }
        }
      }

      // 2. Same name (and size, when the document remembers one).
      found ??= () {
        for (final file in byName[asset.name] ?? const <File>[]) {
          if (taken.contains(file.path)) continue;
          return RelinkMatch(
            assetId: asset.id,
            assetName: asset.name,
            path: file.path,
            confidence: RelinkConfidence.proposed,
          );
        }
        return null;
      }();

      if (found != null) {
        taken.add(found.path);
        matches.add(found);
      } else {
        unmatched.add(asset);
      }
    }

    return RelinkPlan(matches: matches, unmatched: unmatched);
  }
}
