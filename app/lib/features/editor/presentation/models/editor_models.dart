import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../data/project.dart';
import '../../../../state/editor_controller.dart';
import '../../../../core/design/tokens.dart';

enum MediaKind { video, audio, image }

extension MediaKindStyle on MediaKind {
  IconData get icon => switch (this) {
    MediaKind.video => LucideIcons.film,
    MediaKind.audio => LucideIcons.audioWaveform,
    MediaKind.image => LucideIcons.image,
  };

  Gradient get plate => switch (this) {
    MediaKind.video => const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [CcColors.videoPlate2, CcColors.videoPlate],
    ),
    MediaKind.audio => const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF2C5A47), CcColors.audioPlate],
    ),
    MediaKind.image => const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF7A6A4E), Color(0xFF3A3227)],
    ),
  };
}

/// One tile in the media pool.
@immutable
class MediaAsset {
  const MediaAsset({
    required this.name,
    required this.kind,
    required this.meta,
    this.id,
    this.duration,
    this.preparing = false,
    this.thumb,
  });

  final String name;
  final String? id;
  final MediaKind kind;
  final String meta;
  final String? duration;
  final bool preparing;

  /// Decoded-ready JPEG bytes for the plate (null → gradient + icon).
  final Uint8List? thumb;
}

enum TrackKind { video, audio }

enum ClipKind { video, audio, text }

/// A clip laid out on a timeline lane. Times are in seconds.
@immutable
class TimelineClip {
  const TimelineClip({
    required this.label,
    required this.kind,
    required this.start,
    required this.duration,
    this.id,
    this.trackId,
    this.selected = false,
    this.transitionAfterStart = false,
    this.peaks = const [],
  });

  final String label;
  final String? id;

  /// Document track this clip lives on — the drag handler needs it to tell a
  /// same-lane nudge from a cross-lane move.
  final String? trackId;
  final ClipKind kind;
  final double start;
  final double duration;
  final bool selected;

  /// Normalised audio peak envelope; empty falls back to synthetic bars.
  final List<double> peaks;

  /// Draws a transition badge straddling the clip's head.
  final bool transitionAfterStart;

  double get end => start + duration;
}

@immutable
class TimelineTrack {
  const TimelineTrack({
    required this.name,
    required this.kind,
    required this.height,
    this.id,
    this.clips = const [],
    this.locked = false,
    this.hidden = false,
    this.muted = false,
  });

  final String name;
  final String? id;
  final TrackKind kind;
  final double height;
  final List<TimelineClip> clips;
  final bool locked;
  final bool hidden;
  final bool muted;
}

/// A ruler flag (TIM-11).
@immutable
class TimelineMarker {
  const TimelineMarker({required this.id, required this.seconds, this.label = ''});

  final String id;
  final double seconds;
  final String label;
}

/// Layout constant shared by the ruler, the lanes and the playhead.
const double kPixelsPerSecond = 40;

/// Maps a project document onto timeline presentation models. Video tracks
/// stack top-down by descending index (V2 above V1), then the audio lanes.
List<TimelineTrack> tracksFromProject(
  List<Track> tracks,
  List<Clip> clips, {
  String? selectedClipId,
  List<double> Function(String mediaId)? peaksFor,
}) {
  final video = tracks.where((t) => t.kind == 'video').toList()
    ..sort((a, b) => b.index.compareTo(a.index));
  final audio = tracks.where((t) => t.kind == 'audio').toList()
    ..sort((a, b) => a.index.compareTo(b.index));
  final result = <TimelineTrack>[];
  for (final t in [...video, ...audio]) {
    final isVideo = t.kind == 'video';
    final laneClips = clips.where((c) => c.trackId == t.id).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    result.add(
      TimelineTrack(
        id: t.id,
        name: t.name,
        kind: isVideo ? TrackKind.video : TrackKind.audio,
        height: isVideo ? 72 : 56,
        locked: t.lock,
        hidden: t.hidden,
        muted: t.mute,
        clips: [
          for (final c in laneClips)
            TimelineClip(
              id: c.id,
              trackId: c.trackId,
              label: c.label.isEmpty ? '(clip)' : c.label,
              kind: isVideo ? ClipKind.video : ClipKind.audio,
              start: c.start.seconds,
              duration: c.duration.seconds,
              selected: c.id == selectedClipId,
              peaks: isVideo ? const [] : (peaksFor?.call(c.mediaId) ?? const []),
            ),
        ],
      ),
    );
  }
  return result;
}

/// Maps media-pool entries onto presentation models.
MediaAsset poolItemToAsset(PoolItem item, Uint8List? thumb) {
  final a = item.asset;
  final kind = switch (a.type) {
    'audio' => MediaKind.audio,
    'image' => MediaKind.image,
    _ => MediaKind.video,
  };
  final meta = [
    if (kind == MediaKind.video && a.width != null && a.height != null)
      '${a.width}×${a.height}',
    if (a.codec != null) a.codec!.toUpperCase(),
    if (kind != MediaKind.video && a.hasAudio) 'Audio · 48kHz',
  ].join(' · ');
  return MediaAsset(
    id: a.id,
    name: a.name,
    kind: kind,
    meta: meta.isEmpty ? (item.status == ImportStatus.failed ? 'Import failed' : '…') : meta,
    duration: item.status == ImportStatus.ready && !a.duration.isZero
        ? formatDuration(a.duration.seconds)
        : null,
    preparing: item.status == ImportStatus.probing,
    thumb: thumb,
  );
}

String formatDuration(double seconds) {
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
