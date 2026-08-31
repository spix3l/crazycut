part of 'editor_controller.dart';

class AutoCaptionResult {
  const AutoCaptionResult({this.track, this.error, this.cancelled = false});

  final CaptionTrack? track;
  final String? error;
  final bool cancelled;

  bool get succeeded => track != null;
}
