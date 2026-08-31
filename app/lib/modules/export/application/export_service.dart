import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:crazycut_app/modules/project/domain/clip_animation.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/project/domain/caption.dart';
import 'package:crazycut_app/modules/editor/application/caption_interchange.dart';
import 'package:crazycut_app/modules/project/domain/text_content.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/export/domain/export_presets.dart';
import 'package:crazycut_app/core/platform/system_bridge.dart';
import 'package:crazycut_app/modules/editor/infrastructure/caption_rasterizer.dart';
import 'package:crazycut_app/modules/editor/infrastructure/svg_rasterizer.dart';
import 'package:crazycut_app/modules/editor/infrastructure/text_rasterizer.dart';

part 'caption_sidecar_format.dart';
part 'export_job.dart';
part 'export_state.dart';

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
    final active =
        jobs
            .where(
              (j) =>
                  j.state == ExportState.queued ||
                  j.state == ExportState.running,
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

  int get activeCount =>
      jobs
          .where(
            (j) =>
                j.state == ExportState.queued || j.state == ExportState.running,
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
    bool burnCaptions = true,
    CaptionSidecarFormat captionSidecar = CaptionSidecarFormat.none,
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

    // The worker only sees caption tracks when burn-in is requested. Keep the
    // selected sidecar track separately so a sidecar-only export still uses
    // the exact immutable snapshot taken at submit time.
    final captionTracks =
        doc.captionTracks
            .where((track) => track.items.isNotEmpty)
            .map(
              (track) =>
                  captionSidecarTrack(
                    track,
                    startSeconds: start,
                    endSeconds: end,
                  ).toJson(),
            )
            .where((track) => (track['items'] as List<dynamic>).isNotEmpty)
            .toList();
    if (!burnCaptions) snapshot.remove('captionTracks');

    final spec = <String, dynamic>{
      'type': 'timeline',
      'document': snapshot,
      'media': media,
      'output': outputPath,
      'startSec': start,
      'endSec': end,
      'renderWidth': width,
      'renderHeight': height,
      if (captionTracks.isNotEmpty)
        'captionExport': {
          'burnIn': burnCaptions,
          'sidecar': captionSidecar.name,
          'track': captionTracks.first,
        },
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
      _fail(job, 'export worker binary not found. Build the engine');
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
    if (job.state == ExportState.completed) await _writeCaptionSidecar(job);
    await _writeSidecar(job);
    unawaited(_pump());
  }

  /// How finely a typewriter reveal is sampled into textures. 60/s is past
  /// any supported frame rate, so the worker always finds the exact state the
  /// preview showed, without one file per character of a long string.
  static const double _revealSamplesPerSec = 60.0;

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
    final width =
        (job.spec['renderWidth'] as num?)?.toInt() ??
        (settings['width'] as num?)?.toInt() ??
        1920;
    final height =
        (job.spec['renderHeight'] as num?)?.toInt() ??
        (settings['height'] as num?)?.toInt() ??
        1080;

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
      // A clip's own extra payload is spread across its JSON, so the entry
      // animation that drives the reveal is readable straight off the clip.
      final revealSeconds = typewriterRevealSeconds(
        clipAnimSpecOf(clip),
        clipSeconds: clipDuration,
      );
      final runeCount = text.content.runes.length;
      final charsPerSecond =
          revealSeconds == null
              ? 0.0
              : typewriterCharsPerSecond(runeCount, revealSeconds);
      // One texture per *distinct* reveal rather than per character: a fast
      // entry on a long string never shows every intermediate count, and the
      // worker picks the largest variant at or below the frame's count either
      // way. -1 is the whole string, i.e. a clip that does not type in.
      final revealCounts = <int>[];
      if (revealSeconds == null || !charsPerSecond.isFinite) {
        revealCounts.add(-1);
      } else {
        final samples = (revealSeconds * _revealSamplesPerSec).ceil();
        final seen = <int>{};
        for (var sample = 0; sample <= samples; sample++) {
          final count = ((sample / _revealSamplesPerSec) * charsPerSecond)
              .floor()
              .clamp(1, runeCount);
          if (seen.add(count)) revealCounts.add(count);
        }
      }
      for (final revealCount in revealCounts) {
        if (job.state == ExportState.cancelled) break;
        // Render safely inside the reveal interval instead of exactly on its
        // floating-point boundary (where floor(7 / 24 * 24) can become 6).
        final localSeconds =
            revealCount < 0 ? null : (revealCount + 0.25) / charsPerSecond;
        final raster = await TextRasterizer.instance.render(
          text,
          canvasWidth: width,
          sequenceHeight: height,
          localSeconds: localSeconds,
          typewriterSeconds: revealSeconds,
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
          'typewriter': revealSeconds != null,
          'charsPerSecond':
              charsPerSecond.isFinite
                  ? charsPerSecond
                  : kLegacyTypewriterCharsPerSecond,
          'variants': variants,
        };
      }
    }
    for (final trackValue
        in (document['captionTracks'] as List<dynamic>? ?? const [])) {
      if (job.state == ExportState.cancelled || trackValue is! Map) break;
      final track = CaptionTrack.fromJson(trackValue.cast<String, dynamic>());
      for (final item in track.items) {
        if (job.state == ExportState.cancelled || item.text.trim().isEmpty) {
          continue;
        }
        directory ??= await Directory.systemTemp.createTemp('crazycut-text-');
        final variants = <int?>[null];
        if (track.style.highlightWords) {
          variants.addAll(List<int>.generate(item.words.length, (i) => i));
        }
        for (final highlightedWord in variants) {
          final raster = await CaptionRasterizer.instance.render(
            track,
            item,
            canvasWidth: width,
            sequenceHeight: height,
            highlightedWord: highlightedWord,
          );
          if (raster == null) continue;
          final file = File('${directory.path}/${fileIndex++}.rgba');
          await file.writeAsBytes(raster.bytes, flush: false);
          payload[captionTextureKey(
            track,
            item,
            highlightedWord: highlightedWord,
          )] = {
            'startSec': item.start.seconds,
            'typewriter': false,
            'charsPerSecond': kLegacyTypewriterCharsPerSecond,
            'variants': [
              {
                'revealCount': -1,
                'path': file.path,
                'width': raster.width,
                'height': raster.height,
              },
            ],
          };
        }
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
                final reported = (event['totalFrames'] as num?)?.toInt() ?? 0;
                if (reported > 0) job.totalFrames = reported;
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
                final reportedTotal =
                    (event['totalFrames'] as num?)?.toInt() ?? 0;
                if (reportedTotal > 0) job.totalFrames = reportedTotal;
                job.progress = (((event['percent'] as num?) ?? 0).toDouble() /
                        100)
                    .clamp(0, 1);
                job.observeProgress(DateTime.now());
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
    final spec =
        Map<String, dynamic>.from(job.spec)
          ..remove('document')
          ..remove('textTextures');
    if (spec['captionExport'] is Map) {
      spec['captionExport'] = Map<String, dynamic>.from(
        (spec['captionExport'] as Map).cast<String, dynamic>(),
      )..remove('track');
    }
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

  Future<void> _writeCaptionSidecar(ExportJob job) async {
    final export = job.spec['captionExport'];
    if (export is! Map || export['track'] is! Map) return;
    final formatName = export['sidecar']?.toString();
    if (formatName == null || formatName == CaptionSidecarFormat.none.name) {
      return;
    }
    try {
      final track = CaptionTrack.fromJson(
        (export['track'] as Map).cast<String, dynamic>(),
      );
      final (extension, contents) =
          formatName == CaptionSidecarFormat.webVtt.name
              ? ('vtt', CaptionInterchange.exportWebVtt(track))
              : ('srt', CaptionInterchange.exportSrt(track));
      final dot = job.outputPath.lastIndexOf('.');
      final stem = dot > 0 ? job.outputPath.substring(0, dot) : job.outputPath;
      final path = uniquePath('$stem.$extension');
      await File(path).writeAsString(contents, flush: true);
      job.log.add('Caption sidecar: $path');
    } catch (error) {
      // The video is already complete. Keep it, surface the optional sidecar
      // failure in diagnostics, and do not mislabel a valid encode as failed.
      job.log.add('Caption sidecar failed: $error');
    }
  }

  /// Diagnostics text for the "Copy diagnostics" action on a failed job.
  String diagnosticsFor(ExportJob job) {
    final buffer =
        StringBuffer()
          ..writeln('CrazyCut export diagnostics')
          ..writeln('output: ${job.outputPath}')
          ..writeln('state: ${job.state.name}')
          ..writeln('error: ${job.error ?? 'none'}')
          ..writeln('frames: ${job.framesDone}/${job.totalFrames}')
          ..writeln('---');
    for (final line in job.log) {
      buffer.writeln(line);
    }
    return buffer.toString();
  }
}
