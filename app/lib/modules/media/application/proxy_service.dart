import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:crazycut_app/modules/media/infrastructure/media_cache.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/modules/editor/infrastructure/svg_rasterizer.dart';

part 'proxy_job.dart';
part 'proxy_state.dart';

/// Background proxy rendering (IMP-8).
///
/// Proxies are 960×540-equivalent H.264 renders written to the media cache and
/// used for preview decoding while the original stays untouched. One job runs
/// at a time so imports and playback keep the IO budget (arch §5).
class ProxyService extends ChangeNotifier {
  ProxyService({this.enabled = true});

  /// Global "generate proxies" preference (IMP-8).
  bool enabled;

  final Map<String, ProxyJob> jobs = {};
  final List<MediaAsset> _queue = [];
  Process? _process;
  bool _busy = false;

  ProxyState stateOf(String assetId) => jobs[assetId]?.state ?? ProxyState.none;
  double progressOf(String assetId) => jobs[assetId]?.progress ?? 0;
  bool get isBusy => _busy;

  /// Queues [asset] when the rules ask for a proxy, or when [force] is set
  /// (the pool's "Generate proxy now" action).
  void request(MediaAsset asset, {bool force = false}) {
    if (asset.type != 'video') return;
    if (asset.proxyPath != null && File(asset.proxyPath!).existsSync()) return;
    if (!force && (!enabled || !asset.wantsProxy)) return;
    if (jobs[asset.id]?.state == ProxyState.running ||
        jobs[asset.id]?.state == ProxyState.queued) {
      return;
    }
    jobs[asset.id] = ProxyJob(asset.id);
    _queue.add(asset);
    notifyListeners();
    unawaited(_pump());
  }

  void cancelAll() {
    _queue.clear();
    _process?.kill();
    _process = null;
    _busy = false;
  }

  Future<void> _pump() async {
    if (_busy || _queue.isEmpty) return;
    _busy = true;
    while (_queue.isNotEmpty) {
      final asset = _queue.removeAt(0);
      await _render(asset);
    }
    _busy = false;
    notifyListeners();
  }

  Future<void> _render(MediaAsset asset) async {
    final job = jobs[asset.id] ?? ProxyJob(asset.id);
    jobs[asset.id] = job;
    job.state = ProxyState.running;
    notifyListeners();

    final worker = PlatformHelper.workerBinary();
    if (worker == null || !File(worker).existsSync()) {
      job
        ..state = ProxyState.failed
        ..error = 'worker binary not found';
      notifyListeners();
      return;
    }

    final output = await MediaCache.instance.proxyFile(asset);
    final jobFile = File('${output.path}.job.json');
    await jobFile.writeAsString(
      jsonEncode({
        // The local mirror when the source came from a URL: transcoding
        // straight from the network re-downloads what the cache already has.
        'input': mediaDecodePath(asset),
        'output': output.path,
        'video': {
          'codec': 'h264',
          'crf': 23,
          'preset': 'veryfast',
          'maxWidth': 960,
          'maxHeight': 540,
        },
        'audio': asset.hasAudio ? {'codec': 'aac', 'bitrate': 128000} : null,
        'faststart': true,
      }),
    );

    try {
      final process = await Process.start(worker, ['--job', jobFile.path]);
      _process = process;
      final done = Completer<bool>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.trim().isEmpty) return;
          try {
            final event = jsonDecode(line) as Map<String, dynamic>;
            switch (event['type']) {
              case 'progress':
                job.progress =
                    ((event['percent'] as num?) ?? 0).toDouble() / 100;
                notifyListeners();
              case 'done':
                if (!done.isCompleted) done.complete(true);
              case 'fail':
                job.error = event['error']?.toString();
                if (!done.isCompleted) done.complete(false);
            }
          } on Object {
            // Non-JSON chatter from ffmpeg is ignored.
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete(output.existsSync());
        },
      );
      final ok = await done.future;
      await process.exitCode;
      _process = null;
      if (ok && output.existsSync()) {
        asset.proxyPath = output.path;
        job
          ..state = ProxyState.ready
          ..progress = 1;
      } else {
        job.state = ProxyState.failed;
      }
    } on Object catch (e) {
      job
        ..state = ProxyState.failed
        ..error = e.toString();
    } finally {
      if (jobFile.existsSync()) {
        try {
          await jobFile.delete();
        } on Object {
          // Leftover job files are harmless.
        }
      }
      notifyListeners();
    }
  }

  /// Path playback should decode: the proxy when it exists, else the original.
  static String decodePath(MediaAsset asset) {
    final proxy = asset.proxyPath;
    if (proxy != null && File(proxy).existsSync()) return proxy;
    return mediaDecodePath(asset);
  }

  @override
  void dispose() {
    cancelAll();
    super.dispose();
  }
}
