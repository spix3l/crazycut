part of 'tracking_service.dart';

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
    required this.sourceIn,
    required this.sourceWidth,
    this.speed = 1.0,
    this.analysisWidth = 0,
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

  /// Rate to solve at, in clip-local time.
  final Rt fps;

  /// Where the clip starts in the media, and how fast it runs through it. The
  /// solver decodes in *media* time, so a trimmed or retimed clip would
  /// otherwise be tracked against completely different footage.
  final Rt sourceIn;
  final double speed;

  /// Native width of the media, which is what [searchQuad] is expressed in.
  final int sourceWidth;

  /// 0 lets the solver choose from the source's own width.
  final int analysisWidth;
  final String label;
}
