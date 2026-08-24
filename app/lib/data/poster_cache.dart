import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/engine/poster_worker.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/svg_rasterizer.dart';

/// Disk-cached poster frame for a project card, keyed by project id and
/// [ProjectDoc.modifiedAt] so an edited project regenerates its thumbnail
/// while an untouched one never re-renders.
class PosterCache {
  PosterCache._();

  static final PosterCache instance = PosterCache._();

  Directory? _dir;
  final Set<String> _inFlight = {};

  Future<Directory> dir() async {
    final existing = _dir;
    if (existing != null) return existing;
    Directory base;
    try {
      base = await getApplicationCacheDirectory();
    } on Object {
      base = Directory.systemTemp;
    }
    final dir = Directory('${base.path}${Platform.pathSeparator}CrazyCut${Platform.pathSeparator}posters');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _dir = dir;
  }

  String _stamp(ProjectDoc doc) => doc.modifiedAt.millisecondsSinceEpoch.toString();

  Future<File> _fileFor(ProjectDoc doc) async =>
      File('${(await dir()).path}${Platform.pathSeparator}${doc.id}-${_stamp(doc)}.png');

  /// The cached poster file, without triggering a render.
  Future<File?> cached(ProjectDoc doc) async {
    final file = await _fileFor(doc);
    return file.existsSync() ? file : null;
  }

  /// Renders and caches a poster frame for [doc] if one isn't already cached,
  /// then returns its path. Returns null when a render is already underway,
  /// the project has no media to composite, or the engine is unavailable.
  Future<File?> ensure(ProjectDoc doc) async {
    final file = await _fileFor(doc);
    if (file.existsSync()) return file;
    if (!_inFlight.add(file.path)) return null;
    try {
      final duration = doc.sequenceDuration.seconds;
      if (duration <= 0) return null;
      final mediaPaths = <String, String>{
        for (final asset in doc.media)
          if (!asset.offline) asset.id: mediaDecodePath(asset),
      };

      const targetWidth = 640;
      final aspect = doc.settings.height / doc.settings.width;
      final targetHeight = (targetWidth * aspect).round().clamp(1, 4096);

      final frame = await PosterWorker.instance.render(
        projectJson: doc.encode(touchModified: false),
        mediaPaths: mediaPaths,
        time: Rt.fromSeconds((duration * 0.1).clamp(0, duration)),
        width: targetWidth,
        height: targetHeight,
      );
      if (frame == null) return null;

      final png = await _encodePng(frame);
      if (png == null) return null;

      await _purgeStale(doc);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(png, flush: true);
      await tmp.rename(file.path);
      return file;
    } on Object {
      return null;
    } finally {
      _inFlight.remove(file.path);
    }
  }

  Future<Uint8List?> _encodePng(PosterFrame frame) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      frame.rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bytes?.buffer.asUint8List();
  }

  /// Drops posters left behind by earlier revisions of [doc].
  Future<void> _purgeStale(ProjectDoc doc) async {
    final d = await dir();
    if (!d.existsSync()) return;
    final prefix = '${doc.id}-';
    for (final entry in d.listSync().whereType<File>()) {
      final name = entry.uri.pathSegments.last;
      if (name.startsWith(prefix)) {
        try {
          await entry.delete();
        } on Object {
          // Best effort.
        }
      }
    }
  }
}
