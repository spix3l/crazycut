import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/engine/media_worker.dart';

/// Disk + memory cache for derived media (`02-data-model.md` §7): thumbnails,
/// peak envelopes and proxies, all keyed by content hash so they survive a
/// file move and can be deleted at any time.
class MediaCache {
  MediaCache._();

  static final MediaCache instance = MediaCache._();

  Directory? _dir;
  final Map<String, Uint8List> _thumbs = {};
  final Map<String, List<double>> _peaks = {};
  final Set<String> _inFlight = {};

  /// Keeps the decoded-tile map bounded; the timeline only ever shows a few
  /// hundred at a time.
  static const int maxThumbsInMemory = 600;

  Future<Directory> dir() async {
    final existing = _dir;
    if (existing != null) return existing;
    Directory base;
    try {
      base = await getApplicationCacheDirectory();
    } on Object {
      base = Directory.systemTemp;
    }
    final dir = Directory('${base.path}${Platform.pathSeparator}CrazyCut');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _dir = dir;
  }

  String _key(MediaAsset asset) =>
      (asset.hash.isEmpty ? asset.id : asset.hash).replaceAll(':', '_');

  Future<File> _file(MediaAsset asset, String variant) async =>
      File('${(await dir()).path}${Platform.pathSeparator}${_key(asset)}-$variant');

  // --- Thumbnails (IMP-6, TIM-14 filmstrips) --------------------------------

  String _thumbKey(MediaAsset asset, double seconds, int width) =>
      '${_key(asset)}-t${(seconds * 1000).round()}-w$width';

  /// Cached tile, or null when it still has to be decoded.
  Uint8List? thumbNow(MediaAsset asset, double seconds, {int width = 160}) =>
      _thumbs[_thumbKey(asset, seconds, width)];

  /// Decodes (or loads) a tile. [onReady] fires once when it lands so callers
  /// can repaint without awaiting per tile.
  Future<Uint8List?> thumb(
    MediaAsset asset,
    double seconds, {
    int width = 160,
    void Function()? onReady,
  }) async {
    final key = _thumbKey(asset, seconds, width);
    final cached = _thumbs[key];
    if (cached != null) return cached;
    if (_inFlight.contains(key)) return null;
    _inFlight.add(key);
    try {
      final file = File('${(await dir()).path}${Platform.pathSeparator}$key.jpg');
      Uint8List? bytes;
      if (file.existsSync()) {
        bytes = await file.readAsBytes();
      } else {
        bytes = await MediaWorker.instance
            .thumbnail(asset.path, seconds: seconds, width: width);
        if (bytes != null) {
          try {
            await file.writeAsBytes(bytes, flush: false);
          } on Object {
            // A cache write failure is never fatal.
          }
        }
      }
      if (bytes == null) return null;
      if (_thumbs.length >= maxThumbsInMemory) {
        _thumbs.remove(_thumbs.keys.first);
      }
      _thumbs[key] = bytes;
      onReady?.call();
      return bytes;
    } finally {
      _inFlight.remove(key);
    }
  }

  // --- Waveforms (IMP-7) ----------------------------------------------------

  List<double>? peaksNow(MediaAsset asset) => _peaks[_key(asset)];

  Future<List<double>?> peaks(
    MediaAsset asset, {
    int peaksPerSecond = 20,
    void Function()? onReady,
  }) async {
    final key = _key(asset);
    final cached = _peaks[key];
    if (cached != null) return cached;
    if (_inFlight.contains('peaks-$key')) return null;
    _inFlight.add('peaks-$key');
    try {
      final file = await _file(asset, 'peaks.json');
      List<double>? peaks;
      if (file.existsSync()) {
        peaks = (jsonDecode(await file.readAsString()) as List<dynamic>)
            .map((e) => (e as num).toDouble())
            .toList();
      } else {
        peaks = await MediaWorker.instance
            .waveform(asset.path, peaksPerSecond: peaksPerSecond);
        if (peaks != null) {
          try {
            await file.writeAsString(jsonEncode(peaks));
          } on Object {
            // Best effort.
          }
        }
      }
      if (peaks == null) return null;
      _peaks[key] = peaks;
      onReady?.call();
      return peaks;
    } finally {
      _inFlight.remove('peaks-$key');
    }
  }

  // --- Proxies (IMP-8) ------------------------------------------------------

  Future<File> proxyFile(MediaAsset asset) => _file(asset, 'proxy.mp4');

  Future<void> clear() async {
    _thumbs.clear();
    _peaks.clear();
    final d = await dir();
    if (d.existsSync()) d.deleteSync(recursive: true);
    _dir = null;
  }
}
