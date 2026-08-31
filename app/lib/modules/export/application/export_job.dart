part of 'export_service.dart';

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

  /// Estimated when the job is queued, then replaced by the count the worker
  /// reports once it has opened the timeline — that one is authoritative, and
  /// without it a wrong estimate here silently suppressed the ETA.
  int totalFrames;
  final double durationSeconds;

  ExportState state = ExportState.queued;
  double progress = 0;
  int framesDone = 0;

  /// Recent encoding rate, not the average since the job started. An export
  /// opens with work that produces no frames at all (probing, the loudness and
  /// exposure passes, the audio pre-mix), and frames themselves are not
  /// uniform — a plain cut encodes far faster than one under a title. A
  /// lifetime average carries that slow start for minutes and reads as a
  /// wildly pessimistic ETA; this follows what the encoder is doing now.
  double fps = 0;
  DateTime? _rateAt;
  int _rateFrames = 0;
  String? error;
  final List<String> log = [];
  DateTime? startedAt;
  DateTime? finishedAt;
  int outputBytes = 0;
  bool retried = false;

  /// Folds one progress report into the rate, smoothing it so a single slow
  /// or fast stretch does not make the ETA jump around.
  void observeProgress(DateTime now) {
    final since = _rateAt;
    if (since != null) {
      final seconds = now.difference(since).inMilliseconds / 1000;
      final frames = framesDone - _rateFrames;
      if (seconds >= 0.5 && frames > 0) {
        final sample = frames / seconds;
        fps = fps <= 0 ? sample : fps * 0.7 + sample * 0.3;
        _rateAt = now;
        _rateFrames = framesDone;
      }
      return;
    }
    _rateAt = now;
    _rateFrames = framesDone;
  }

  /// Seconds left at the current rate, or null while there is nothing to
  /// estimate from.
  double? get etaSeconds {
    if (totalFrames > 0 && framesDone > 0) {
      if (framesDone >= totalFrames) return null;
      if (fps > 0) return (totalFrames - framesDone) / fps;
    }
    // No frame count to work from — fall back to how long the fraction done
    // has taken. Slower to settle, but it always gives the user a number.
    final started = startedAt;
    if (started == null || progress <= 0 || progress >= 1) return null;
    final elapsed = DateTime.now().difference(started).inMilliseconds / 1000;
    if (elapsed <= 0) return null;
    return elapsed * (1 - progress) / progress;
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
    final remaining = etaSeconds;
    final eta =
        remaining != null ? ' · ${formatRemaining(remaining)} left' : '';
    return 'Encoding · $percent%$rate$eta';
  }

  /// Time left, at the coarseness the number deserves: an hour-long export
  /// does not need its seconds, and "85:00" reads as a timecode rather than as
  /// an hour and a half.
  static String formatRemaining(double seconds) {
    if (seconds < 10) return 'a few seconds';
    if (seconds < 60) return '${(seconds / 5).round() * 5}s';
    if (seconds < 3600) {
      final m = seconds ~/ 60;
      final s = (seconds % 60).round();
      return m < 5 ? '${m}m ${s}s' : '${m}m';
    }
    final h = seconds ~/ 3600;
    final m = ((seconds % 3600) / 60).round();
    return m > 0 ? '${h}h ${m}m' : '${h}h';
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '';
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
