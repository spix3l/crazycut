import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../models/editor_models.dart';

/// A clip drawn on a lane. The three kinds share a footprint but differ in
/// plate colour and in where the name plate sits.
class TimelineClipTile extends StatelessWidget {
  const TimelineClipTile({
    super.key,
    required this.clip,
    required this.height,
    this.selected = false,
  });

  final TimelineClip clip;
  final double height;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return switch (clip.kind) {
      ClipKind.video => _VideoClip(clip: clip, height: height, selected: selected),
      ClipKind.audio => _AudioClip(clip: clip, height: height, selected: selected),
      ClipKind.text => _TextClip(clip: clip, height: height, selected: selected),
    };
  }
}

BoxDecoration _clipBox(bool selected, {Gradient? gradient, Color? color, Color? border}) {
  return BoxDecoration(
    gradient: gradient,
    color: color,
    borderRadius: BorderRadius.circular(4),
    border: Border.all(
      color: selected ? CcColors.accent : (border ?? CcColors.borderStrong),
      width: selected ? 2 : 1,
    ),
  );
}

class _NamePlate extends StatelessWidget {
  const _NamePlate({required this.icon, required this.label, required this.height, required this.color});

  final IconData icon;
  final String label;
  final double height;
  final Color color;

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
        ],
      ),
    );
  }
}

class _VideoClip extends StatelessWidget {
  const _VideoClip({required this.clip, required this.height, required this.selected});

  final TimelineClip clip;
  final double height;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: _clipBox(selected, gradient: MediaKind.video.plate),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _NamePlate(
            icon: LucideIcons.film,
            label: clip.label,
            height: 18,
            color: const Color(0x80000000),
          ),
        ],
      ),
    );
  }
}

class _AudioClip extends StatelessWidget {
  const _AudioClip({required this.clip, required this.height, required this.selected});

  final TimelineClip clip;
  final double height;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: _clipBox(selected, color: CcColors.audioPlate),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _NamePlate(
            icon: LucideIcons.audioWaveform,
            label: clip.label,
            height: 16,
            color: const Color(0x60000000),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
              child: CustomPaint(
                size: Size.infinite,
                painter: WaveformPainter(seed: clip.label.length),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TextClip extends StatelessWidget {
  const _TextClip({required this.clip, required this.height, required this.selected});

  final TimelineClip clip;
  final double height;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: _clipBox(selected, color: CcColors.textClipPlate, border: CcColors.textClip),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CcIcon(LucideIcons.type, size: 10, color: CcColors.textClip),
          const SizedBox(height: 2),
          Text(
            clip.label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            softWrap: false,
            style: CcType.style(size: 10, weight: CcType.medium),
          ),
        ],
      ),
    );
  }
}

/// Deterministic bar waveform — the shape only depends on [seed], so it stays
/// stable across rebuilds.
class WaveformPainter extends CustomPainter {
  const WaveformPainter({this.seed = 0, this.color = CcColors.audioWave});

  final int seed;
  final Color color;

  static const _pattern = [0.25, 0.5, 0.75, 0.42, 0.92, 0.58, 0.33, 0.67, 0.83, 0.5];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const barWidth = 3.0;
    const step = 5.0;
    var i = seed;
    for (var x = 0.0; x + barWidth <= size.width; x += step) {
      final amplitude = _pattern[i++ % _pattern.length];
      final barHeight = (size.height * amplitude).clamp(3.0, size.height);
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
      oldDelegate.seed != seed || oldDelegate.color != color;
}

/// The hourglass badge that straddles a cut between two video clips.
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
