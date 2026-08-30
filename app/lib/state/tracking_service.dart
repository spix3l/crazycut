/// Area tracking as a background job (**TRK-5**).
///
/// Shaped after [TranscriptionService], which is itself shaped after
/// [ProxyService]: a serial queue driving the `crazycut_worker` sidecar over
/// the same JSON-lines protocol. Rate and ETA come from [ExportJob] rather
/// than being re-derived, because a solve has exactly the export's problem of
/// a slow start that reports no movement at all while the first frames decode.
///
/// Nothing here is modal. A solve runs while the user keeps editing, and
/// cancelling it leaves the document byte-identical (**TRK-10**).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:crazycut_app/data/area_track.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/export_service.dart';
import 'package:crazycut_app/state/svg_rasterizer.dart';

enum TrackingState { none, queued, running, ready, failed, cancelled }

/// What a caller asks the solver for. The identity of the run is [trackerId],
/// so re-tracking a region replaces its job rather than queueing a second one.
class TrackingRequest {
  const TrackingRequest({
    required this.trackerId,
    required this.asset,
    required this.sourceClipId,
    required this.searchQuad,
    required this.startTime,
    required this.endTime,
    required this.fps,
    this.analysisWidth = 720,
    this.label = 'Region',
  });

  final String trackerId;
  final MediaAsset asset;
  final String sourceClipId;

  /// The drawn region in source px, TL/TR/BR/BL.
  final Quad searchQuad;

  /// Clip-local range to solve.
  final Rt startTime;
  final Rt endTime;

  /// Rate to solve at, normally the media's own.
  final Rt fps;

  final int analysisWidth;
  final String label;
}

class TrackingJob {
  TrackingJob(this.request);

  final TrackingRequest request;

  TrackingState state = TrackingState.queued;
  double progress = 0;
  String? error;
  DateTime? startedAt;

  double _rateAt = 0;
  double _rateProgress = 0;
  double _rate = 0;

  /// Folds a progress report into a smoothed rate, ignoring the opening
  /// stretch where the first decode produces no movement.
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
    TrackingState.none => '',
    TrackingState.queued => 'Queued · waiting…',
    TrackingState.running => _runningStatus,
    TrackingState.ready => 'Tracked',
    TrackingState.failed => 'Failed · ${error ?? 'unknown error'}',
    TrackingState.cancelled => 'Cancelled',
  };

  String get _runningStatus {
    final percent = (progress * 100).clamp(0, 100).toStringAsFixed(0);
    final remaining = etaSeconds;
    // Same vocabulary as an export, because it is the same kind of wait.
    final eta = remaining != null
        ? ' · ${ExportJob.formatRemaining(remaining)} left'
        : '';
    return 'Tracking ${request.label} · $percent%$eta';
  }
}

class TrackingService extends ChangeNotifier {
  TrackingService();

  static final TrackingService instance = TrackingService();

  /// Overridable for tests, which have no worker binary to run.
  @visibleForTesting
  Future<Map<String, dynamic>?> Function(TrackingJob job)? solveOverride;

  final Map<String, TrackingJob> jobs = {};
  final List<TrackingRequest> _queue = [];
  final Map<String, List<Completer<Tracker?>>> _waiters = {};
  Process? _process;
  bool _busy = false;
  String? _runningTrackerId;

  bool get isBusy => _busy;

  TrackingState stateOf(String trackerId) =>
      jobs[trackerId]?.state ?? TrackingState.none;

  TrackingJob? jobFor(String trackerId) => jobs[trackerId];

  /// Queues a solve and completes with the finished [Tracker], or null when the
  /// run failed or was cancelled. The document is not touched here — the caller
  /// installs the result as one undoable command (**TRK-15**).
  Future<Tracker?> solve(TrackingRequest request) {
    final completer = Completer<Tracker?>();
    _waiters.putIfAbsent(request.trackerId, () => []).add(completer);

    // Re-tracking a region supersedes an in-flight solve for the same tracker
    // rather than racing it.
    cancel(request.trackerId, notify: false);

    jobs[request.trackerId] = TrackingJob(request);
    _queue.add(request);
    notifyListeners();
    unawaited(_pump());
    return completer.future;
  }

  void cancel(String trackerId, {bool notify = true}) {
    _queue.removeWhere((r) => r.trackerId == trackerId);
    final job = jobs[trackerId];
    if (job == null) return;
    if (job.state == TrackingState.ready) return;
    job.state = TrackingState.cancelled;
    if (_runningTrackerId == trackerId) {
      _process?.kill();
    } else {
      _finish(trackerId, null);
    }
    if (notify) notifyListeners();
  }

  void cancelAll() {
    _queue.clear();
    _process?.kill();
    for (final entry in jobs.entries) {
      if (entry.value.state == TrackingState.queued) {
        entry.value.state = TrackingState.cancelled;
        _finish(entry.key, null);
      }
    }
    notifyListeners();
  }

  void _finish(String trackerId, Tracker? tracker) {
    final waiters = _waiters.remove(trackerId);
    if (waiters == null) return;
    for (final w in waiters) {
      if (!w.isCompleted) w.complete(tracker);
    }
  }

  Future<void> _pump() async {
    if (_busy || _queue.isEmpty) return;
    _busy = true;
    try {
      while (_queue.isNotEmpty) {
        await _run(_queue.removeAt(0));
      }
    } finally {
      _busy = false;
      _runningTrackerId = null;
      notifyListeners();
    }
  }

  Future<void> _run(TrackingRequest request) async {
    final job = jobs[request.trackerId];
    if (job == null || job.state == TrackingState.cancelled) {
      _finish(request.trackerId, null);
      return;
    }

    job.state = TrackingState.running;
    job.startedAt = DateTime.now();
    _runningTrackerId = request.trackerId;
    notifyListeners();

    Map<String, dynamic>? payload;
    try {
      payload = solveOverride != null
          ? await solveOverride!(job)
          : await _runWorker(job);
    } on Object catch (e) {
      _fail(job, 'Tracking could not start: $e');
      return;
    } finally {
      _process = null;
    }

    if (job.state == TrackingState.cancelled || payload == null) {
      if (job.state != TrackingState.cancelled && job.error == null) {
        job.error = 'The solver produced no path.';
        job.state = TrackingState.failed;
      }
      _finish(request.trackerId, null);
      notifyListeners();
      return;
    }

    final tracker = _trackerFrom(request, payload);
    if (tracker == null) {
      _fail(job, 'The solved path was unreadable.');
      return;
    }
    job.state = TrackingState.ready;
    job.progress = 1;
    _finish(request.trackerId, tracker);
    notifyListeners();
  }

  Future<Map<String, dynamic>?> _runWorker(TrackingJob job) async {
    final worker = PlatformHelper.workerBinary();
    if (worker == null) {
      _fail(job, 'The CrazyCut worker could not be found.');
      return null;
    }

    final request = job.request;
    final dir = await Directory.systemTemp.createTemp('cc-track');
    final output = File('${dir.path}/track.json');
    final jobFile = File('${dir.path}/track.job.json');
    try {
      await jobFile.writeAsString(
        jsonEncode({
          'type': 'track',
          // The cached mirror for URL sources: the solver reads frame after
          // frame, which is the worst thing to do over HTTP.
          'input': mediaDecodePath(request.asset),
          'output': output.path,
          'quad': request.searchQuad,
          'startSec': request.startTime.seconds,
          'endSec': request.endTime.seconds,
          'fps': request.fps.seconds,
          'analysisWidth': request.analysisWidth,
        }),
      );

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

      if (job.state == TrackingState.cancelled) return null;
      if (code != 0) {
        job.state = TrackingState.failed;
        job.error ??= 'The worker stopped with code $code.';
        return null;
      }
      if (!output.existsSync()) {
        job.state = TrackingState.failed;
        job.error ??= 'The worker wrote no track.';
        return null;
      }
      final decoded = jsonDecode(await output.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } finally {
      try {
        if (dir.existsSync()) await dir.delete(recursive: true);
      } on Object {
        // A leftover temp dir is harmless; the OS reclaims it.
      }
    }
  }

  void _handleLine(TrackingJob job, String line) {
    if (line.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      // Worker chatter (ffmpeg) is not an error.
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
          job.state = TrackingState.cancelled;
        } else {
          job.error = message;
        }
      case 'done':
        job.progress = 1;
    }
  }

  /// Builds the document entity from the worker's payload. Returns null for
  /// anything [Tracker.fromJson] would reject, so a malformed solve never
  /// reaches the document.
  Tracker? _trackerFrom(TrackingRequest request, Map<String, dynamic> payload) {
    // The solver may decimate, and it reports by how much. Dividing the
    // requested rational rate is exact, where rebuilding a rational from the
    // reported float is not: 30 fps decimated by 7 is 30/7, not 4.286.
    final stride = (payload['stride'] as num?)?.toInt() ?? 1;
    if (stride < 1) return null;
    final storedFps = Rt(request.fps.num, request.fps.den * stride);
    if (storedFps.num <= 0) return null;
    return Tracker.fromJson({
      ...payload,
      'id': request.trackerId,
      'mediaId': request.asset.id,
      'sourceClipId': request.sourceClipId,
      'startTime': request.startTime.toString(),
      'endTime': request.endTime.toString(),
      'searchQuad': request.searchQuad,
      'fps': storedFps.toString(),
    });
  }

  void _fail(TrackingJob job, String message) {
    job.state = TrackingState.failed;
    job.error = message;
    _finish(job.request.trackerId, null);
    notifyListeners();
  }
}
