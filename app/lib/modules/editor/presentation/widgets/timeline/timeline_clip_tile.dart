import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;

// The document's `Clip` shadows Flutter's clip-behaviour enum; the enum is
// reachable as ui.Clip on the rare occasions this file needs it.
import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/editor/presentation/models/editor_models.dart';

part 'keyframe_ribbon_painter.dart';
part 'track_confidence_stripe_painter.dart';
part 'transition_badge.dart';
part 'waveform_painter.dart';

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
    this.onFadeDrag,
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

  /// Corner fade drag: `(isFadeIn, deltaSeconds)`.
  final void Function(bool fadeIn, double deltaSeconds)? onFadeDrag;

  bool get _isAudio => audio || asset?.type == 'audio';
  bool get _offline => asset?.offline ?? false;

  @override
  Widget build(BuildContext context) {
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
            else if (tileAt != null)
              _Filmstrip(
                clip: clip,
                pxPerSec: pxPerSec,
                height: height,
                tileAt: tileAt!,
              ),
            Align(
              alignment:
                  _isAudio ? Alignment.topCenter : Alignment.bottomCenter,
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
                curve: clip.fadeIn.curve,
              ),
            if (!clip.fadeOut.duration.isZero)
              _FadeTriangle(
                width: clip.fadeOut.duration.seconds * pxPerSec,
                height: height,
                fromLeft: false,
                curve: clip.fadeOut.curve,
              ),
            // Corner grips: drag to set a fade (AUD-2). Only on clips that
            // actually carry sound, so a silent b-roll tile stays clean, and
            // only when the tile is wide enough that the two grips leave
            // something in between to grab for a move.
            if (onFadeDrag != null &&
                (asset?.hasAudio ?? false) &&
                clip.duration.seconds * pxPerSec >= _kFadeHandlePx * 3) ...[
              _FadeHandle(
                fromLeft: true,
                active: !clip.fadeIn.duration.isZero,
                onDelta: (dx) => onFadeDrag!(true, dx / pxPerSec),
              ),
              _FadeHandle(
                fromLeft: false,
                active: !clip.fadeOut.duration.isZero,
                onDelta: (dx) => onFadeDrag!(false, -dx / pxPerSec),
              ),
            ],
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
    return ((clip.sourceIn.seconds + clip.sourceSpan.seconds) / total).clamp(
      0.0,
      1.0,
    );
  }
}

class _OfflineSlate extends StatelessWidget {
  const _OfflineSlate();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _CheckerPainter(),
      child: const Center(
        child: CcIcon(
          LucideIcons.unlink,
          size: 12,
          color: CcColors.textSecondary,
        ),
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
                        final bytes = tileAt(
                          clip.sourceIn.seconds + i * secondsPerTile,
                        );
                        if (bytes == null) return const SizedBox.shrink();
                        return Image.memory(
                          bytes,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        );
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // At high zoom-out a clip can be narrower than the icon itself. Keep
        // the name plate painted, but remove content before Row gets an
        // impossible minimum width and reports a RenderFlex overflow.
        final showIcon = width >= 12;
        final showLabel = width >= 34;
        final showLinked = linked && width >= 52;
        final showMuted = muted && width >= 68;
        final horizontalPadding = width >= 24 ? 6.0 : 0.0;
        return Container(
          height: height,
          color: color,
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Row(
            children: [
              if (showIcon)
                CcIcon(icon, size: 9, color: const Color(0xDDFFFFFF)),
              if (showLabel) ...[
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: CcType.style(
                      size: 9,
                      weight: CcType.medium,
                      color: const Color(0xEEFFFFFF),
                    ),
                  ),
                ),
              ],
              if (showLinked)
                const CcIcon(
                  LucideIcons.link,
                  size: 8,
                  color: Color(0x99FFFFFF),
                ),
              if (showMuted) ...[
                const SizedBox(width: 3),
                const CcIcon(
                  LucideIcons.volumeOff,
                  size: 8,
                  color: Color(0x99FFFFFF),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The fade wedge over a clip's head or tail. It traces the actual gain curve
/// (AUD-2), so an exponential fade looks different from a linear one — the
/// drawing and the mixer read the same curve name.
class _FadeTriangle extends StatelessWidget {
  const _FadeTriangle({
    required this.width,
    required this.height,
    required this.fromLeft,
    this.curve = 'linear',
  });

  final double width;
  final double height;
  final bool fromLeft;
  final String curve;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: fromLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: CustomPaint(
        size: Size(width.clamp(0, 400), height),
        painter: _FadePainter(fromLeft: fromLeft, curve: curve),
      ),
    );
  }
}

class _FadePainter extends CustomPainter {
  const _FadePainter({required this.fromLeft, required this.curve});

  final bool fromLeft;
  final String curve;

  /// Same shapes the mixer applies: p, p², and smoothstep.
  static double _gain(double p, String curve) => switch (curve) {
    'exponential' => p * p,
    'scurve' => p * p * (3 - 2 * p),
    _ => p,
  };

  @override
  void paint(Canvas canvas, Size size) {
    const steps = 24;
    final path = Path()..moveTo(fromLeft ? 0 : size.width, 0);
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final gain = _gain(t, curve);
      final x = fromLeft ? size.width * t : size.width * (1 - t);
      path.lineTo(x, size.height * (1 - gain));
    }
    path.lineTo(fromLeft ? 0 : size.width, size.height);
    canvas.drawPath(path..close(), Paint()..color = const Color(0x55000000));
  }

  @override
  bool shouldRepaint(_FadePainter oldDelegate) =>
      oldDelegate.fromLeft != fromLeft || oldDelegate.curve != curve;
}

/// Side of a square fade grip, in logical pixels.
const double _kFadeHandlePx = 12;

/// Draggable corner grip. Sits inside the trim zone's inner edge so trimming
/// and fading do not fight over the same pixels (UX note in the audio spec).
class _FadeHandle extends StatelessWidget {
  const _FadeHandle({
    required this.fromLeft,
    required this.active,
    required this.onDelta,
  });

  final bool fromLeft;
  final bool active;
  final ValueChanged<double> onDelta;

  static const _editPointerDevices = <ui.PointerDeviceKind>{
    ui.PointerDeviceKind.mouse,
    ui.PointerDeviceKind.touch,
    ui.PointerDeviceKind.stylus,
    ui.PointerDeviceKind.invertedStylus,
    ui.PointerDeviceKind.unknown,
  };

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: fromLeft ? Alignment.topLeft : Alignment.topRight,
      child: GestureDetector(
        supportedDevices: _editPointerDevices,
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDelta(d.delta.dx),
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: Container(
            width: _kFadeHandlePx,
            height: _kFadeHandlePx,
            alignment: Alignment.center,
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: active ? CcColors.accent : const Color(0x66FFFFFF),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
