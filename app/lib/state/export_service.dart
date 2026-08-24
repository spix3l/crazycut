import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/text_content.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/export_presets.dart';
import 'package:crazycut_app/state/system_bridge.dart';
import 'package:crazycut_app/state/svg_rasterizer.dart';
import 'package:crazycut_app/state/text_rasterizer.dart';

enum ExportState { queued, running, completed, failed, cancelled }

/// One queued export. Jobs are immutable in what they render: the document
/// snapshot is taken at submit time (EXP-2), so editing on after pressing
/// Export cannot change a file that is already queued.
class ExportJob {
  ExportJob({
    required this.id,
    required this.name,
    required this.outputPath,
    required this.spec,
    required this.totalFrames,
    required this.durationSeconds,
  });

  final String id;

  /// Display name (the output file's basename).
  final String name;
  final String outputPath;

  /// The full worker job, document snapshot included.
  final Map<String, dynamic> spec;

  final int totalFrames;
  final double durationSeconds;

  ExportState state = ExportState.queued;
  double progress = 0;
  int framesDone = 0;
  double fps = 0;
  String? error;
  final List<String> log = [];
  DateTime? startedAt;
  DateTime? finishedAt;
  int outputBytes = 0;
  bool retried = false;

  /// Seconds left at the current rate, or null before there is a rate.
  double? get etaSeconds {
    if (fps <= 0 || totalFrames <= 0 || framesDone >= totalFrames) return null;
    return (totalFrames - framesDone) / fps;
  }

  String get statusLine => switch (state) {
        ExportState.queued => 'Queued · waiting…',
        ExportState.running => _runningStatus,
        ExportState.completed =>
          'Completed · ${_formatDuration(finishedAt!.difference(startedAt!))}'
              ' · ${_formatBytes(outputBytes)}',
        ExportState.failed => 'Failed · ${error ?? 'unknown error'}',
        ExportState.cancelled => 'Cancelled',
      };

  String get _runningStatus {
    final percent = (progress * 100).clamp(0, 100).toStringAsFixed(0);
    final rate = fps > 0 ? ' · ${fps.toStringAsFixed(0)} fps' : '';
    final eta = etaSeconds != null
        ? ' · ETA ${_formatDuration(Duration(seconds: etaSeconds!.round()))}'
        : '';
    return 'Encoding · $percent%$rate$eta';
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '—';
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

/// Runs export jobs in the worker process, one (or two) at a time, while the
/// editor keeps running (EXP-9/10). Nothing here touches the live document:
/// jobs carry their own snapshot.
class ExportService extends ChangeNotifier {
  ExportService._() {
    // The host asks us to stand down when the user quits mid-export.
    SystemBridge.instance.onCancelExports = cancelAll;
  }

  static final ExportService instance = ExportService._();

  final List<ExportJob> jobs = [];
  final Map<String, Process> _processes = {};

  @override
  void notifyListeners() {
    super.notifyListeners();
    // Keep the host in step so quitting can warn and sleep stays disabled.
    final active = jobs
        .where(
          (j) =>
              j.state == ExportState.queued || j.state == ExportState.running,
        )
        .map((j) => j.name)
        .toList();
    if (!listEquals(active, _publishedActive)) {
      _publishedActive = active;
      unawaited(SystemBridge.instance.setActiveExports(active));
    }
  }

  List<String> _publishedActive = const [];

  /// Configurable parallelism 1–2 (EXP-9). One by default: two encodes on the
  /// same machine mostly steal cycles from each other and from preview.
  int parallelism = 1;

  bool get hasActiveJobs => jobs.any(
        (j) => j.state == ExportState.queued || j.state == ExportState.running,
      );

  int get activeCount => jobs
      .where(
        (j) => j.state == ExportState.queued || j.state == ExportState.running,
      )
      .length;

  /// Builds a job from the document as it is right now (EXP-2) and queues it.
  ExportJob submit({
    required ProjectDoc doc,
    required ExportPreset preset,
    required String outputPath,
    required ExportQuality quality,
    bool hardware = false,
    bool loudness = false,
    bool levelClips = false,
    bool matchExposure = false,
    Rt? rangeStart,
    Rt? rangeEnd,
  }) {
    final snapshot =
        jsonDecode(doc.encode(touchModified: false)) as Map<String, dynamic>;
    final media = <String, String>{};
    for (final asset in doc.media) {
      if (asset.offline) continue;
      // Export always reads the originals, never the proxies.
      media[asset.id] = mediaDecodePath(asset);
    }

    final start = rangeStart?.seconds ?? 0;
    final end = rangeEnd?.seconds ?? doc.sequenceDuration.seconds;
    final fps = doc.settings.fpsValue;
    final (width, height) = preset.outputSize(doc.settings);

    final spec = <String, dynamic>{
      'type': 'timeline',
      'document': snapshot,
      'media': media,
      'output': outputPath,
      'startSec': start,
      'endSec': end,
      'video': {
        'codec': preset.videoCodec,
        'crf': quality.crf,
        'preset': quality.preset,
        'maxWidth': preset.maxWidth,
        'maxHeight': preset.maxHeight,
        'hardware': hardware,
        if (matchExposure) 'matchExposure': true,
      },
      'audio': {
        'codec': preset.audioCodec,
        'bitrate': preset.audioBitrate,
        if (loudness) 'loudnessLufs': -14.0,
        if (loudness) 'truePeakDb': -1.5,
        if (levelClips) 'levelClips': true,
      },
      'faststart': preset.faststart,
    };

    final job = ExportJob(
      id: generateId(),
      name: outputPath.split(Platform.pathSeparator).last,
      outputPath: outputPath,
      spec: spec,
      totalFrames: ((end - start) * fps).round(),
      durationSeconds: end - start,
    );
    job.log.add(
      'Preset ${preset.name} · $width×$height · '
      '${quality.label}${hardware ? ' · hardware' : ''}',
    );
    jobs.add(job);
    notifyListeners();
    unawaited(_pump());
    return job;
  }

  /// Names that already exist get ` (1)`, ` (2)`… — never a silent overwrite.
  static String uniquePath(String path) {
    if (!File(path).existsSync()) return path;
    final dot = path.lastIndexOf('.');
    final stem = dot > 0 ? path.substring(0, dot) : path;
    final ext = dot > 0 ? path.substring(dot) : '';
    for (var i = 1; i < 1000; i++) {
      final candidate = '$stem ($i)$ext';
      if (!File(candidate).existsSync()) return candidate;
    }
    return path;
  }

  void cancel(String jobId) {
    final job = jobs.firstWhere((j) => j.id == jobId);
    if (job.state == ExportState.completed) return;
    _processes.remove(jobId)?.kill();
    job.state = ExportState.cancelled;
    // EXP-3 integrity: cancelling leaves nothing behind.
    _removePartials(job);
    notifyListeners();
    unawaited(_pump());
  }

  void cancelAll() {
    for (final job in jobs.toList()) {
      if (job.state == ExportState.queued || job.state == ExportState.running) {
        cancel(job.id);
      }
    }
  }

  void clearFinished() {
    jobs.removeWhere(
      (j) =>
          j.state == ExportState.completed ||
          j.state == ExportState.failed ||
          j.state == ExportState.cancelled,
    );
    notifyListeners();
  }

  Future<void> _pump() async {
    while (true) {
      final running = jobs.where((j) => j.state == ExportState.running).length;
      if (running >= parallelism) return;
      ExportJob? next;
      for (final job in jobs) {
        if (job.state == ExportState.queued) {
          next = job;
          break;
        }
      }
      if (next == null) return;
      unawaited(_run(next));
      // Give the job a moment to leave `queued` before looking again.
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> _run(ExportJob job) async {
    job.state = ExportState.running;
    job.startedAt = DateTime.now();
    notifyListeners();

    final worker = PlatformHelper.workerBinary();
    if (worker == null || !File(worker).existsSync()) {
      _fail(job, 'export worker binary not found — build the engine');
      return;
    }
    job.log.add('Worker: $worker');

    final jobFile = File('${job.outputPath}.job.json');
    Directory? textTextureDir;
    try {
      textTextureDir = await _prepareTextTextures(job);
      if (job.state == ExportState.cancelled) {
        await _deleteTextureDir(textTextureDir);
        return;
      }
      await jobFile.writeAsString(jsonEncode(job.spec));
    } catch (e) {
      await _deleteTextureDir(textTextureDir);
      _fail(job, 'cannot prepare export inputs: $e');
      return;
    }

    final ok = await _spawn(job, worker, jobFile);
    // EXP-11: one automatic retry before showing a failure.
    if (!ok && job.state == ExportState.failed && !job.retried) {
      job.retried = true;
      job.log.add('Retrying once after failure…');
      job.state = ExportState.running;
      job.error = null;
      notifyListeners();
      await _spawn(job, worker, jobFile);
    }

    if (await jobFile.exists()) {
      try {
        await jobFile.delete();
      } catch (_) {
        // A leftover job file is harmless.
      }
    }
    await _deleteTextureDir(textTextureDir);
    await _writeSidecar(job);
    unawaited(_pump());
  }

  /// Flutter owns text shaping, so export snapshots the resulting tight RGBA
  /// textures into temporary raw files that the native worker can read. A
  /// static title needs one texture; typewriter titles carry one texture per
  /// visible character count so their per-frame reveal stays deterministic.
  Future<Directory?> _prepareTextTextures(ExportJob job) async {
    final document = job.spec['document'] as Map<String, dynamic>;
    final clips = (document['clips'] as List<dynamic>? ?? const []);
    final tracks = (document['tracks'] as List<dynamic>? ?? const []);
    final hiddenTracks = <String>{
      for (final value in tracks)
        if (value is Map && value['hidden'] == true)
          value['id']?.toString() ?? '',
    };
    final settings = document['settings'] as Map<String, dynamic>? ?? const {};
    final width = (settings['width'] as num?)?.toInt() ?? 1920;
    final height = (settings['height'] as num?)?.toInt() ?? 1080;

    Directory? directory;
    final payload = <String, dynamic>{};
    var fileIndex = 0;
    for (final value in clips) {
      if (job.state == ExportState.cancelled) break;
      if (value is! Map) continue;
      final clip = value.cast<String, dynamic>();
      final textJson = clip['text'];
      if (textJson is! Map || hiddenTracks.contains(clip['trackId'])) continue;
      final id = clip['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final text = TextContent.fromJson(textJson.cast<String, dynamic>());
      if (text.content.isEmpty) continue;
      directory ??= await Directory.systemTemp.createTemp('crazycut-text-');

      final variants = <Map<String, dynamic>>[];
      final clipDuration = Rt.parse(clip['duration'] as String).seconds;
      final maxRevealCount = math.min(
        text.content.runes.length,
        (clipDuration * 24).ceil(),
      );
      final revealCounts = text.animation == 'typewriter'
          ? List<int>.generate(maxRevealCount, (i) => i + 1)
          : const <int>[-1];
      for (final revealCount in revealCounts) {
        if (job.state == ExportState.cancelled) break;
        // Render safely inside the reveal interval instead of exactly on its
        // floating-point boundary (where floor(7 / 24 * 24) can become 6).
        final localSeconds =
            revealCount < 0 ? null : (revealCount + 0.25) / 24.0;
        final raster = await TextRasterizer.instance.render(
          text,
          canvasWidth: width,
          sequenceHeight: height,
          localSeconds: localSeconds,
        );
        if (raster == null) continue;
        final file = File('${directory.path}/${fileIndex++}.rgba');
        await file.writeAsBytes(raster.bytes, flush: false);
        variants.add({
          'revealCount': revealCount,
          'path': file.path,
          'width': raster.width,
          'height': raster.height,
        });
      }
      if (variants.isNotEmpty) {
        payload['text:$id'] = {
          'startSec': Rt.parse(clip['start'] as String).seconds,
          'typewriter': text.animation == 'typewriter',
          'variants': variants,
        };
      }
    }
    if (payload.isNotEmpty) job.spec['textTextures'] = payload;
    return directory;
  }

  Future<void> _deleteTextureDir(Directory? directory) async {
    if (directory == null || !await directory.exists()) return;
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // Temporary export inputs are best-effort cleanup, like job sidecars.
    }
  }

  Future<bool> _spawn(ExportJob job, String worker, File jobFile) async {
    final stopwatch = Stopwatch()..start();
    Process process;
    try {
      process = await Process.start(worker, ['--job', jobFile.path]);
    } catch (e) {
      _fail(job, 'cannot start worker: $e');
      return false;
    }
    _processes[job.id] = process;

    final finished = Completer<bool>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        if (line.trim().isEmpty) return;
        Map<String, dynamic> event;
        try {
          event = jsonDecode(line) as Map<String, dynamic>;
        } on Object {
          job.log.add(line); // ffmpeg chatter, kept for diagnostics
          return;
        }
        switch (event['type']) {
          case 'started':
            job.log.add(
              'Rendering ${event['width']}×${event['height']} · '
              '${event['totalFrames']} frames',
            );
          case 'encoder':
            job.log.add('Encoder: ${event['video']}');
          case 'note':
            // Analysis passes report what they adjusted (AUD-16 / EXP-15).
            if (event['message']?.toString().isNotEmpty ?? false) {
              job.log.add(event['message'].toString());
            }
          case 'progress':
            job.framesDone =
                (event['frame'] as num?)?.toInt() ?? job.framesDone;
            job.progress = (((event['percent'] as num?) ?? 0).toDouble() / 100)
                .clamp(0, 1);
            final elapsed = stopwatch.elapsedMilliseconds / 1000;
            if (elapsed > 0) job.fps = job.framesDone / elapsed;
            notifyListeners();
          case 'done':
            job.outputBytes = (event['bytes'] as num?)?.toInt() ?? 0;
            if (!finished.isCompleted) finished.complete(true);
          case 'fail':
            job.error = event['error']?.toString();
            job.log.add('Error: ${job.error}');
            if (!finished.isCompleted) finished.complete(false);
        }
      },
      onDone: () {
        if (!finished.isCompleted) {
          finished.complete(File(job.outputPath).existsSync());
        }
      },
    );
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      // Keep the tail only; ffmpeg is chatty and the log is for diagnostics.
      job.log.add(line);
      if (job.log.length > 200) job.log.removeAt(0);
    });

    final ok = await finished.future;
    await process.exitCode;
    _processes.remove(job.id);

    if (job.state == ExportState.cancelled) return false;
    if (ok && File(job.outputPath).existsSync()) {
      job.state = ExportState.completed;
      job.progress = 1;
      job.framesDone = job.totalFrames;
      job.finishedAt = DateTime.now();
      if (job.outputBytes == 0) {
        job.outputBytes = File(job.outputPath).lengthSync();
      }
      notifyListeners();
      return true;
    }
    _fail(job, job.error ?? 'the worker produced no output');
    return false;
  }

  void _fail(ExportJob job, String message) {
    job.state = ExportState.failed;
    job.error = message;
    job.finishedAt = DateTime.now();
    _removePartials(job);
    notifyListeners();
  }

  void _removePartials(ExportJob job) {
    for (final path in [
      '${job.outputPath}.part',
      '${job.outputPath}.job.json',
    ]) {
      final file = File(path);
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {
          // Best effort: a stale partial is not worth failing over.
        }
      }
    }
  }

  /// EXP-14: a sidecar next to the output recording what produced it.
  Future<void> _writeSidecar(ExportJob job) async {
    if (job.state == ExportState.cancelled) return;
    final spec = Map<String, dynamic>.from(job.spec)
      ..remove('document')
      ..remove('textTextures');
    final report = {
      'output': job.outputPath,
      'state': job.state.name,
      'error': job.error,
      'startedAt': job.startedAt?.toIso8601String(),
      'finishedAt': job.finishedAt?.toIso8601String(),
      'durationSeconds': job.durationSeconds,
      'frames': job.totalFrames,
      'bytes': job.outputBytes,
      'settings': spec,
      'log':
          job.log.length > 40 ? job.log.sublist(job.log.length - 40) : job.log,
    };
    try {
      await File(
        '${job.outputPath}.log.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    } catch (e) {
      debugPrint('export sidecar failed: $e');
    }
  }

  /// Diagnostics text for the "Copy diagnostics" action on a failed job.
  String diagnosticsFor(ExportJob job) {
    final buffer = StringBuffer()
      ..writeln('CrazyCut export diagnostics')
      ..writeln('output: ${job.outputPath}')
      ..writeln('state: ${job.state.name}')
      ..writeln('error: ${job.error ?? '—'}')
      ..writeln('frames: ${job.framesDone}/${job.totalFrames}')
      ..writeln('---');
    for (final line in job.log) {
      buffer.writeln(line);
    }
    return buffer.toString();
  }
}
