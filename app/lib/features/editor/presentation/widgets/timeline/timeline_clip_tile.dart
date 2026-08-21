import 'dart:typed_data';
import 'dart:ui' as ui;

// The document's `Clip` shadows Flutter's clip-behaviour enum; the enum is
// reachable as ui.Clip on the rare occasions this file needs it.
import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/project.dart';
import '../../models/editor_models.dart';

/// A clip drawn on a lane: filmstrip or waveform body, name plate, and the
/// selection outline. Offline media renders as a slate (IMP-17).
class TimelineClipTile extends StatelessWidget {
  const TimelineClipTile({
    super.key,
    required this.clip,
    required this.asset,
    required this.height,
    required this.pxPerSec,
    required this.audio,
    this.selected = false,
    this.peaks = const [],
    this.tileAt,
    this.dimmed = false,
  });

  final Clip clip;
  final MediaAsset? asset;

  /// Lane kind, not asset kind: the audio half of a linked A/V pair points at
  /// the same video file but must draw as a waveform.
  final bool audio;
  final double height;
  final double pxPerSec;
  final bool selected;
  final List<double> peaks;

  /// Returns the filmstrip tile for a source time, or null while it decodes.
  final Uint8List? Function(double sourceSeconds)? tileAt;

  /// Locked or hidden tracks draw at reduced contrast.
  final bool dimmed;

  bool get _isAudio => audio || asset?.type == 'audio';
  bool get _offline => asset?.offline ?? false;

  @override
  Widget build(BuildContext context) {
    final width = clip.duration.seconds * pxPerSec;
    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: _isAudio ? null : MediaKind.video.plate,
          color: _isAudio ? CcColors.audioPlate : null,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected ? CcColors.accent : CcColors.borderStrong,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: ui.Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_offline)
              const _OfflineSlate()
            else if (_isAudio)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 18, 4, 4),
                child: CustomPaint(
                  size: Size.infinite,
                  painter: WaveformPainter(
                    seed: clip.label.length,
                    peaks: peaks,
                    startFraction: _peakStart,
                    endFraction: _peakEnd,
                  ),
                ),
              )
            else if (pxPerSec >= kFilmstripMinPxPerSec && tileAt != null && width > 40)
              _Filmstrip(clip: clip, pxPerSec: pxPerSec, height: height, tileAt: tileAt!),
            Align(
              alignment: _isAudio ? Alignment.topCenter : Alignment.bottomCenter,
              child: _NamePlate(
                icon: _isAudio ? LucideIcons.audioWaveform : LucideIcons.film,
                label: clip.label,
                muted: clip.mute,
                linked: clip.linkedGroup != null,
                height: _isAudio ? 16 : 18,
                color: const Color(0x90000000),
              ),
            ),
            if (!clip.fadeIn.duration.isZero)
              _FadeTriangle(
                width: clip.fadeIn.duration.seconds * pxPerSec,
                height: height,
                fromLeft: true,
              ),
            if (!clip.fadeOut.duration.isZero)
              _FadeTriangle(
                width: clip.fadeOut.duration.seconds * pxPerSec,
                height: height,
                fromLeft: false,
              ),
          ],
        ),
      ),
    );
  }

  /// Which slice of the asset's peak envelope this clip shows.
  double get _peakStart {
    final total = asset?.duration.seconds ?? 0;
    if (total <= 0) return 0;
    return (clip.sourceIn.seconds / total).clamp(0.0, 1.0);
  }

  double get _peakEnd {
    final total = asset?.duration.seconds ?? 0;
    if (total <= 0) return 1;
    return ((clip.sourceIn.seconds + clip.sourceSpan.seconds) / total).clamp(0.0, 1.0);
  }
}

class _OfflineSlate extends StatelessWidget {
  const _OfflineSlate();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _CheckerPainter(),
      child: const Center(
        child: CcIcon(LucideIcons.unlink, size: 12, color: CcColors.textSecondary),
      ),
    );
  }
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final dark = Paint()..color = const Color(0xFF2A2C31);
    final light = Paint()..color = const Color(0xFF34373D);
    canvas.drawRect(Offset.zero & size, dark);
    const cell = 8.0;
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        if (((x ~/ cell) + (y ~/ cell)).isEven) continue;
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), light);
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter oldDelegate) => false;
}

/// Poster tiles laid end to end across the clip (TIM-14). Tiles are requested
/// lazily; missing ones just leave the plate gradient showing.
class _Filmstrip extends StatelessWidget {
  const _Filmstrip({
    required this.clip,
    required this.pxPerSec,
    required this.height,
    required this.tileAt,
  });

  final Clip clip;
  final double pxPerSec;
  final double height;
  final Uint8List? Function(double sourceSeconds) tileAt;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = height * 16 / 9;
        final count = (constraints.maxWidth / tileWidth).ceil().clamp(1, 40);
        final secondsPerTile = tileWidth / pxPerSec * clip.speedValue;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            maxWidth: double.infinity,
            child: Row(
              children: [
                for (var i = 0; i < count; i++)
                  SizedBox(
                    width: tileWidth,
                    height: height,
                    child: Builder(
                      builder: (context) {
                        final bytes = tileAt(clip.sourceIn.seconds + i * secondsPerTile);
                        if (bytes == null) return const SizedBox.shrink();
                        return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _NamePlate extends StatelessWidget {
  const _NamePlate({
    required this.icon,
    required this.label,
    required this.height,
    required this.color,
    this.muted = false,
    this.linked = false,
  });

  final IconData icon;
  final String label;
  final double height;
  final Color color;
  final bool muted;
  final bool linked;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          CcIcon(icon, size: 9, color: const Color(0xDDFFFFFF)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
              style: CcType.style(size: 9, weight: CcType.medium, color: const Color(0xEEFFFFFF)),
            ),
          ),
          if (linked) const CcIcon(LucideIcons.link, size: 8, color: Color(0x99FFFFFF)),
          if (muted) ...[
            const SizedBox(width: 3),
            const CcIcon(LucideIcons.volumeOff, size: 8, color: Color(0x99FFFFFF)),
          ],
        ],
      ),
    );
  }
}

/// The classic fade wedge drawn over a clip's head or tail.
class _FadeTriangle extends StatelessWidget {
  const _FadeTriangle({required this.width, required this.height, required this.fromLeft});

  final double width;
  final double height;
  final bool fromLeft;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: fromLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: CustomPaint(
        size: Size(width.clamp(0, 400), height),
        painter: _FadePainter(fromLeft: fromLeft),
      ),
    );
  }
}

class _FadePainter extends CustomPainter {
  const _FadePainter({required this.fromLeft});

  final bool fromLeft;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (fromLeft) {
      path.moveTo(0, 0);
      path.lineTo(size.width, 0);
      path.lineTo(0, size.height);
    } else {
      path.moveTo(size.width, 0);
      path.lineTo(0, 0);
      path.lineTo(size.width, size.height);
    }
    canvas.drawPath(path..close, Paint()..color = const Color(0x55000000));
  }

  @override
  bool shouldRepaint(_FadePainter oldDelegate) => oldDelegate.fromLeft != fromLeft;
}

/// Bar waveform. With real [peaks] it renders the slice the clip uses; without
/// them it falls back to a deterministic pattern so the lane never looks empty.
class WaveformPainter extends CustomPainter {
  const WaveformPainter({
    this.seed = 0,
    this.color = CcColors.audioWave,
    this.peaks = const [],
    this.startFraction = 0,
    this.endFraction = 1,
  });

  final int seed;
  final Color color;
  final List<double> peaks;
  final double startFraction;
  final double endFraction;

  static const _pattern = [0.25, 0.5, 0.75, 0.42, 0.92, 0.58, 0.33, 0.67, 0.83, 0.5];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const barWidth = 3.0;
    const step = 5.0;
    final columns = ((size.width - barWidth) / step).floor() + 1;
    var i = seed;
    var column = 0;
    for (var x = 0.0; x + barWidth <= size.width; x += step) {
      double amplitude;
      if (peaks.isEmpty) {
        amplitude = _pattern[i++ % _pattern.length];
      } else {
        final t = columns <= 1 ? 0.0 : column / (columns - 1);
        final fraction = startFraction + (endFraction - startFraction) * t;
        final index = (fraction * (peaks.length - 1)).round().clamp(0, peaks.length - 1);
        amplitude = peaks[index];
      }
      column++;
      final barHeight = (size.height * amplitude).clamp(2.0, size.height);
      final top = (size.height - barHeight) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, barWidth, barHeight),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) =>
      oldDelegate.seed != seed ||
      oldDelegate.color != color ||
      oldDelegate.peaks.length != peaks.length ||
      oldDelegate.startFraction != startFraction ||
      oldDelegate.endFraction != endFraction;
}

/// The hourglass badge straddling a cut where a transition lives.
class TransitionBadge extends StatelessWidget {
  const TransitionBadge({super.key, required this.height, this.width = 24, this.selected = false});

  final double height;
  final double width;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: MediaKind.video.plate,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(
          color: selected ? CcColors.accent : const Color(0x30FFFFFF),
          width: selected ? 2 : 1,
        ),
      ),
      child: const CcIcon(LucideIcons.hourglass, size: 12, color: Color(0xDDFFFFFF)),
    );
  }
}
