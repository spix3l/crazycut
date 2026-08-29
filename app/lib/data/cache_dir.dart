import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The one directory every derived-media cache writes into
/// (`02-data-model.md` §7): thumbnails, peaks, proxies, SVG rasters and the
/// local mirrors of remote sources. Kept in one place so a cache clear and the
/// per-asset invalidation both see the same files.
Future<Directory> mediaCacheDirectory() async {
  Directory base;
  try {
    base = await getApplicationCacheDirectory();
  } on Object {
    base = Directory.systemTemp;
  }
  final dir = Directory('${base.path}${Platform.pathSeparator}CrazyCut');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// Cache file names are keyed by content hash where there is one, so a moved
/// file keeps its derivatives, and by asset id otherwise (remote sources are
/// never hashed).
String mediaCacheKey({required String hash, required String id}) =>
    (hash.isEmpty ? id : hash).replaceAll(':', '_');
