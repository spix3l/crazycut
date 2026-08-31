import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:crazycut_app/modules/media/infrastructure/cache_dir.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';

const _localSourceKey = 'localSource';

/// Remote sources larger than this keep streaming from the server: mirroring a
/// multi-gigabyte file on import would be worse than the seek cost it saves,
/// and oversized video already gets a proxy.
const int kMaxMirroredRemoteBytes = 512 << 20;

/// The on-disk mirror of [asset]'s remote source, or null when there is not
/// one (yet, too large, or the cache was cleared).
String? localRemoteSource(MediaAsset asset) {
  final path = asset.extra[_localSourceKey];
  if (path is String && path.isNotEmpty && File(path).existsSync()) {
    return path;
  }
  return null;
}

/// Drops the mirror reference. The file itself is removed by
/// [MediaCache.invalidate], which owns every derivative of one asset.
void forgetLocalRemoteSource(MediaAsset asset) =>
    asset.extra.remove(_localSourceKey);

/// Downloads URL-imported media once so everything downstream decodes from a
/// local file.
///
/// Decoding straight from the URL works, but only forwards: seeking a remote
/// source re-opens the connection, and formats without a keyframe index — GIF
/// above all, where every frame depends on the first — must re-read the file
/// from byte 0 to answer any backward seek. A remote GIF measured 10-25 ms per
/// frame while playing forward and 0.4-1.7 s for every scrub, loop or playhead
/// jump, which is what made the monitor sit frozen on URL media instead of
/// playing it. Some hosts also refuse range requests altogether, so seeking
/// them is not slow but impossible.
class RemoteSourceCache {
  RemoteSourceCache._();

  static final RemoteSourceCache instance = RemoteSourceCache._();

  /// Swapped in tests to serve from a local HTTP fixture.
  http.Client Function() clientFactory = http.Client.new;

  final Map<String, Future<String?>> _inFlight = {};

  /// True while [asset] is being mirrored, so the pool can say so.
  bool isMirroring(MediaAsset asset) => _inFlight.containsKey(asset.id);

  /// Returns the local mirror for [asset], downloading it when needed. Returns
  /// null when the asset is not remote, is too large to mirror, or the
  /// download failed — callers then keep using the URL.
  Future<String?> ensure(MediaAsset asset) {
    if (!asset.isRemote) return Future.value(null);
    final existing = localRemoteSource(asset);
    if (existing != null) return Future.value(existing);
    final running = _inFlight[asset.id];
    if (running != null) return running;
    // A block body on purpose: `Map.remove` hands back the very future being
    // completed, and an arrow callback would make `whenComplete` wait on it.
    final future = _download(asset).whenComplete(() {
      _inFlight.remove(asset.id);
    });
    _inFlight[asset.id] = future;
    return future;
  }

  Future<String?> _download(MediaAsset asset) async {
    if ((asset.remoteContentLength ?? 0) > kMaxMirroredRemoteBytes) return null;
    final client = clientFactory();
    IOSink? sink;
    File? partial;
    try {
      final target = File(
        '${(await mediaCacheDirectory()).path}${Platform.pathSeparator}'
        '${mediaCacheKey(hash: asset.hash, id: asset.id)}-source'
        '${_extensionFor(asset.path)}',
      );
      partial = File('${target.path}.part');
      final response = await client
          .send(http.Request('GET', Uri.parse(asset.path)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('HTTP ${response.statusCode}');
      }
      if ((response.contentLength ?? 0) > kMaxMirroredRemoteBytes) return null;
      sink = partial.openWrite();
      var written = 0;
      await for (final chunk in response.stream) {
        written += chunk.length;
        if (written > kMaxMirroredRemoteBytes) {
          throw StateError('remote source exceeds the mirror limit');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (target.existsSync()) await target.delete();
      await partial.rename(target.path);
      partial = null;
      asset.extra[_localSourceKey] = target.path;
      return target.path;
    } on Object {
      // A mirror is an optimization: on any failure the URL still decodes.
      return null;
    } finally {
      try {
        await sink?.close();
        if (partial != null && partial.existsSync()) await partial.delete();
      } on Object {
        // Nothing useful to do about a failed cleanup.
      }
      client.close();
    }
  }
}

/// The mirror keeps the source's extension: FFmpeg's demuxer probing is
/// content-based, but a matching name keeps the cache readable and lets the
/// image demuxers pick themselves.
String _extensionFor(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  final ext = name.substring(dot).toLowerCase();
  return RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(ext) ? ext : '';
}
