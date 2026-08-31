part of 'transcription_service.dart';

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
