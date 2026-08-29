/// Local speech-to-text as a background job (AI-18, AI-20, AI-21).
///
/// Shaped after [ProxyService]: a serial queue driving the same
/// `crazycut_worker` sidecar over the same JSON-lines protocol. Rate and ETA
/// come from [ExportJob] rather than being re-derived — a long transcription
/// has exactly the export's problem of a slow start that produces no progress
/// at all (decode, then model load), and re-implementing the smoothing is how
/// you reproduce the bug that made ETAs useless before.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:crazycut_app/ai/ai_settings.dart';
import 'package:crazycut_app/data/media_cache.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/transcript.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/state/export_service.dart';
import 'package:crazycut_app/state/speech_model.dart';
import 'package:crazycut_app/state/svg_rasterizer.dart';

enum TranscriptionState { none, queued, running, ready, failed, cancelled }

class TranscriptionJob {
  TranscriptionJob(this.assetId, this.assetName);

  final String assetId;
  final String assetName;

  TranscriptionState state = TranscriptionState.queued;
  double progress = 0;
  String? error;
  DateTime? startedAt;

  double _rateAt = 0;
  double _rateProgress = 0;
  double _rate = 0;

  /// Folds a progress report into a smoothed rate, ignoring the opening
  /// stretch where the decode and model load produce no movement.
  void observe(DateTime now) {
    final started = startedAt;
    if (started == null) return;
    final elapsed = now.difference(started).inMilliseconds / 1000;
    if (_rateAt == 0) {
      _rateAt = elapsed;
      _rateProgress = progress;
      return;
    }
    final seconds = elapsed - _rateAt;
    final delta = progress - _rateProgress;
    if (seconds >= 0.5 && delta > 0) {
      final sample = delta / seconds;
      _rate = _rate <= 0 ? sample : _rate * 0.7 + sample * 0.3;
      _rateAt = elapsed;
      _rateProgress = progress;
    }
  }

  double? get etaSeconds {
    if (progress <= 0 || progress >= 1) return null;
    if (_rate > 0) return (1 - progress) / _rate;
    final started = startedAt;
    if (started == null) return null;
    final elapsed = DateTime.now().difference(started).inMilliseconds / 1000;
    if (elapsed <= 0) return null;
    return elapsed * (1 - progress) / progress;
  }

  String get statusLine => switch (state) {
    TranscriptionState.none => '',
    TranscriptionState.queued => 'Queued · waiting…',
    TranscriptionState.running => _runningStatus,
    TranscriptionState.ready => 'Transcribed',
    TranscriptionState.failed => 'Failed · ${error ?? 'unknown error'}',
    TranscriptionState.cancelled => 'Cancelled',
  };

  String get _runningStatus {
    final percent = (progress * 100).clamp(0, 100).toStringAsFixed(0);
    final remaining = etaSeconds;
    // Same vocabulary as an export, because it is the same kind of wait.
    final eta =
        remaining != null
            ? ' · ${ExportJob.formatRemaining(remaining)} left'
            : '';
    return 'Transcribing · $percent%$eta';
  }
}

class TranscriptionService extends ChangeNotifier {
  TranscriptionService({SpeechModelStore? models})
    : _models = models ?? SpeechModelStore.instance;

  static final TranscriptionService instance = TranscriptionService();

  final SpeechModelStore _models;

  /// Which speech model to use. Read from the saved configuration rather than
  /// held here, so there is exactly one answer to the question.
  String? modelIdOverride;
  String get modelId => modelIdOverride ?? AiSettings.instance.speechModelId;

  final Map<String, TranscriptionJob> jobs = {};
  final List<MediaAsset> _queue = [];
  Process? _process;
  bool _busy = false;
  String? _runningAssetId;

  final Map<String, List<Completer<Transcript?>>> _waiters = {};

  TranscriptionState stateOf(String assetId) =>
      jobs[assetId]?.state ?? TranscriptionState.none;

  TranscriptionJob? jobFor(String assetId) => jobs[assetId];

  bool get isBusy => _busy;

  /// Returns the cached transcript if there is one, otherwise queues the work
  /// and completes when it lands. Returns null when transcription is not
  /// possible — no audio, no model, or the run failed.
  Future<Transcript?> ensure(MediaAsset asset) async {
    final cached = await MediaCache.instance.transcript(asset);
    if (cached != null) {
      jobs[asset.id] =
          TranscriptionJob(asset.id, asset.name)
            ..state = TranscriptionState.ready
            ..progress = 1;
      return cached;
    }

    if (!asset.hasAudio) return null;

    final completer = Completer<Transcript?>();
    _waiters.putIfAbsent(asset.id, () => []).add(completer);

    final existing = jobs[asset.id]?.state;
    if (existing != TranscriptionState.queued &&
        existing != TranscriptionState.running) {
      jobs[asset.id] = TranscriptionJob(asset.id, asset.name);
      _queue.add(asset);
      notifyListeners();
      unawaited(_pump());
    }
    return completer.future;
  }

  void cancel(String assetId) {
    _queue.removeWhere((a) => a.id == assetId);
    final job = jobs[assetId];
    if (job == null) return;
    if (_runningAssetId == assetId) {
      job.state = TranscriptionState.cancelled;
      _process?.kill();
    } else {
      job.state = TranscriptionState.cancelled;
      _finish(assetId, null);
    }
    notifyListeners();
  }

  void cancelAll() {
    _queue.clear();
    _process?.kill();
    for (final entry in jobs.entries) {
      if (entry.value.state == TranscriptionState.queued) {
        entry.value.state = TranscriptionState.cancelled;
        _finish(entry.key, null);
      }
    }
    notifyListeners();
  }

  void _finish(String assetId, Transcript? transcript) {
    final waiters = _waiters.remove(assetId);
    if (waiters == null) return;
    for (final w in waiters) {
      if (!w.isCompleted) w.complete(transcript);
    }
  }

  Future<void> _pump() async {
    if (_busy || _queue.isEmpty) return;
    _busy = true;
    try {
      while (_queue.isNotEmpty) {
        final asset = _queue.removeAt(0);
        await _run(asset);
      }
    } finally {
      _busy = false;
      _runningAssetId = null;
      notifyListeners();
    }
  }

  Future<void> _run(MediaAsset asset) async {
    final job = jobs[asset.id];
    if (job == null || job.state == TranscriptionState.cancelled) {
      _finish(asset.id, null);
      return;
    }

    final worker = PlatformHelper.workerBinary();
    if (worker == null) {
      _fail(job, 'The CrazyCut worker could not be found.');
      return;
    }

    final model = speechModelById(modelId);
    final modelPath = await _models.pathIfInstalled(model);
    if (modelPath == null) {
      // Never downloads behind the user's back — the caller is expected to
      // have offered the download first (AI-19).
      _fail(
        job,
        'The ${model.label} speech model is not installed '
        '(${model.sizeLabel}).',
      );
      return;
    }

    final output = await MediaCache.instance.transcriptFile(asset);
    final jobFile = File('${output.path}.job.json');
    try {
      await jobFile.writeAsString(
        jsonEncode({
          'type': 'transcribe',
          // The cached mirror for URL sources: whisper reads the file end to
          // end, which is the worst thing to do over HTTP.
          'input': mediaDecodePath(asset),
          'output': output.path,
          'model': modelPath,
          // An English-only model cannot meaningfully detect a language, and
          // asking it to will report a confident wrong answer. Multilingual
          // models get 'auto'.
          'language': model.id.endsWith('.en') ? 'en' : 'auto',
          'threads': 0,
        }),
      );
    } on Object catch (e) {
      _fail(job, 'Could not write the transcription job: $e');
      return;
    }

    job.state = TranscriptionState.running;
    job.startedAt = DateTime.now();
    _runningAssetId = asset.id;
    notifyListeners();

    try {
      final process = await Process.start(worker, ['--job', jobFile.path]);
      _process = process;

      final stderrDrain = process.stderr.drain<void>();
      await for (final line in process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        _handleLine(job, line);
      }
      final code = await process.exitCode;
      await stderrDrain;
      _process = null;

      if (job.state == TranscriptionState.cancelled) {
        _finish(asset.id, null);
      } else if (code == 0) {
        final transcript = await MediaCache.instance.transcript(asset);
        job.state = TranscriptionState.ready;
        job.progress = 1;
        _finish(asset.id, transcript);
      } else {
        job.state = TranscriptionState.failed;
        job.error ??= 'The worker stopped with code $code.';
        _finish(asset.id, null);
      }
    } on Object catch (e) {
      _fail(job, 'Transcription could not start: $e');
    } finally {
      _process = null;
      try {
        if (jobFile.existsSync()) await jobFile.delete();
      } on Object {
        // Leftover job files are harmless; the next run overwrites.
      }
      notifyListeners();
    }
  }

  void _handleLine(TranscriptionJob job, String line) {
    if (line.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      // Worker chatter (ffmpeg, ggml) is not an error.
      return;
    }
    if (decoded is! Map<String, dynamic>) return;

    switch (decoded['type']) {
      case 'progress':
        final percent = (decoded['percent'] as num?)?.toDouble();
        if (percent != null) {
          job.progress = (percent / 100).clamp(0.0, 1.0);
          job.observe(DateTime.now());
          notifyListeners();
        }
      case 'fail':
        final message = decoded['error'] as String? ?? 'unknown error';
        if (message.contains('cancelled')) {
          job.state = TranscriptionState.cancelled;
        } else {
          job.error = message;
        }
      case 'done':
        job.progress = 1;
    }
  }

  void _fail(TranscriptionJob job, String message) {
    job.state = TranscriptionState.failed;
    job.error = message;
    _finish(job.assetId, null);
    notifyListeners();
  }
}
