import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
    this.duration,
    this.preparing = false,
  });

  final String name;
  final MediaKind kind;
  final String meta;
  final String? duration;
  final bool preparing;
}

const sampleAssets = <MediaAsset>[
  MediaAsset(name: 'IMG_4021.mov', kind: MediaKind.video, meta: '1080×1920', duration: '0:32'),
  MediaAsset(name: 'broll_desk.mp4', kind: MediaKind.video, meta: '1920×1080', duration: '1:12'),
  MediaAsset(name: 'voiceover.wav', kind: MediaKind.audio, meta: 'Audio · 48kHz', duration: '2:04'),
  MediaAsset(name: 'bg_music.mp3', kind: MediaKind.audio, meta: 'Audio · 48kHz', duration: '3:15'),
  MediaAsset(name: 'logo.png', kind: MediaKind.image, meta: 'Image · PNG'),
  MediaAsset(name: 'b_roll.mov', kind: MediaKind.video, meta: 'Preparing…', preparing: true),
];

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
    this.selected = false,
    this.transitionAfterStart = false,
  });

  final String label;
  final ClipKind kind;
  final double start;
  final double duration;
  final bool selected;

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
    this.clips = const [],
  });

  final String name;
  final TrackKind kind;
  final double height;
  final List<TimelineClip> clips;
}

/// Layout constant shared by the ruler, the lanes and the playhead.
const double kPixelsPerSecond = 40;

const sampleTracks = <TimelineTrack>[
  TimelineTrack(
    name: 'V2',
    kind: TrackKind.video,
    height: 48,
    clips: [
      TimelineClip(
        label: 'golden hour, every time',
        kind: ClipKind.text,
        start: 7.4,
        duration: 5.5,
        selected: true,
      ),
      TimelineClip(
        label: 'thanks for watching!',
        kind: ClipKind.text,
        start: 27,
        duration: 4.25,
      ),
    ],
  ),
  TimelineTrack(
    name: 'V1',
    kind: TrackKind.video,
    height: 72,
    clips: [
      TimelineClip(label: 'IMG_4021.mov', kind: ClipKind.video, start: 0, duration: 7.7),
      TimelineClip(
        label: 'broll_desk.mp4',
        kind: ClipKind.video,
        start: 7.1,
        duration: 9.05,
        transitionAfterStart: true,
      ),
      TimelineClip(label: 'b_roll_walk.mov', kind: ClipKind.video, start: 16.4, duration: 6.5),
    ],
  ),
  TimelineTrack(
    name: 'A1',
    kind: TrackKind.audio,
    height: 48,
    clips: [
      TimelineClip(label: 'voiceover.wav', kind: ClipKind.audio, start: 0, duration: 12),
    ],
  ),
  TimelineTrack(
    name: 'A2',
    kind: TrackKind.audio,
    height: 48,
    clips: [
      TimelineClip(label: 'bg_music_upbeat.mp3', kind: ClipKind.audio, start: 0, duration: 23),
    ],
  ),
];

const emptyTracks = <TimelineTrack>[
  TimelineTrack(name: 'V1', kind: TrackKind.video, height: 72),
  TimelineTrack(name: 'A1', kind: TrackKind.audio, height: 56),
];
