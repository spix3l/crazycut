import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../models/editor_models.dart';
import 'timeline_clip_tile.dart';
import 'track_header.dart';

/// Bottom half of the editor: tool strip, ruler, track headers, lanes and the
/// playhead. Presentation only — nothing here moves on its own.
class TimelinePanel extends StatelessWidget {
  const TimelinePanel({
    super.key,
    required this.tracks,
    this.playheadSeconds = 12.1,
    this.durationSeconds = 36,
    this.showGettingStartedHint = false,
    this.selectedKey,
    this.onSelect,
  });

  static const double rulerHeight = 24;

  final List<TimelineTrack> tracks;
  final double playheadSeconds;
  final double durationSeconds;
  final bool showGettingStartedHint;

  /// Identity of the selected clip or transition, see [timelineKey].
  final String? selectedKey;
  final ValueChanged<String>? onSelect;

  @override
  Widget build(BuildContext context) {
    final lanesHeight = tracks.fold<double>(0, (sum, t) => sum + t.height);

    return Container(
      decoration: const BoxDecoration(color: CcColors.panel, border: CcBorders.top),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _TimelineToolbar(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: TrackHeaderTile.width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: rulerHeight,
                        decoration: const BoxDecoration(
                          color: CcColors.panel,
                          border: Border(
                            right: BorderSide(color: CcColors.border),
                            bottom: BorderSide(color: CcColors.border),
                          ),
                        ),
                      ),
                      for (final track in tracks) TrackHeaderTile(track: track),
                      Expanded(
                        child: Container(
                          decoration: const BoxDecoration(border: CcBorders.right),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final contentWidth =
                          (durationSeconds * kPixelsPerSecond).clamp(constraints.maxWidth, 1 / 0);
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: contentWidth,
                          child: Stack(
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  TimelineRuler(
                                    width: contentWidth,
                                    durationSeconds: durationSeconds,
                                  ),
                                  for (final track in tracks)
                                    _Lane(
                                      track: track,
                                      selectedKey: selectedKey,
                                      onSelect: onSelect,
                                    ),
                                ],
                              ),
                              if (showGettingStartedHint)
                                Positioned(
                                  top: rulerHeight,
                                  left: 0,
                                  width: contentWidth,
                                  height: lanesHeight,
                                  child: const _GettingStartedHint(),
                                ),
                              Positioned(
                                left: playheadSeconds * kPixelsPerSecond - 5,
                                top: 0,
                                height: rulerHeight + lanesHeight,
                                child: const _Playhead(),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineToolbar extends StatelessWidget {
  const _TimelineToolbar();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(border: CcBorders.bottom),
      child: Row(
        children: [
          const CcIcon(LucideIcons.scissors, size: 14),
          const SizedBox(width: 14),
          const CcIcon(LucideIcons.trash2, size: 14),
          const SizedBox(width: 14),
          const CcIcon(LucideIcons.flag, size: 14),
          const SizedBox(width: 14),
          const CcDivider(height: 16),
          const SizedBox(width: 14),
          Text('+ Track', style: CcType.style(size: 11, color: CcColors.textSecondary)),
          const Spacer(),
          const CcIcon(LucideIcons.zoomOut, size: 14),
          const SizedBox(width: 10),
          const SizedBox(width: 80, child: CcSlider(value: 0.55, trackHeight: 3, handleSize: 9)),
          const SizedBox(width: 10),
          const CcIcon(LucideIcons.zoomIn, size: 14),
          const SizedBox(width: 10),
          const CcIcon(LucideIcons.scan, size: 14, color: CcColors.textTertiary),
        ],
      ),
    );
  }
}

/// Second ruler with a tick every five seconds.
class TimelineRuler extends StatelessWidget {
  const TimelineRuler({super.key, required this.width, required this.durationSeconds});

  final double width;
  final double durationSeconds;

  @override
  Widget build(BuildContext context) {
    final ticks = (durationSeconds / 5).ceil();
    return Container(
      height: TimelinePanel.rulerHeight,
      width: width,
      decoration: const BoxDecoration(color: CcColors.panel, border: CcBorders.bottom),
      child: Stack(
        children: [
          for (var i = 0; i <= ticks; i++) ...[
            Positioned(
              left: i * 5 * kPixelsPerSecond,
              bottom: 0,
              child: Container(width: 1, height: 8, color: CcColors.borderStrong),
            ),
            Positioned(
              left: i * 5 * kPixelsPerSecond + 4,
              top: 4,
              child: Text('0:${(i * 5).toString().padLeft(2, '0')}', style: CcType.nano),
            ),
          ],
        ],
      ),
    );
  }
}

/// Stable identity for a clip (or its transition) inside a track.
String timelineKey(TimelineTrack track, TimelineClip clip, {bool transition = false}) =>
    '${track.name}/${clip.label}${transition ? '#transition' : ''}';

class _Lane extends StatelessWidget {
  const _Lane({required this.track, this.selectedKey, this.onSelect});

  final TimelineTrack track;
  final String? selectedKey;
  final ValueChanged<String>? onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: track.height,
      decoration: const BoxDecoration(color: CcColors.bg, border: CcBorders.bottom),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final clip in track.clips)
            Positioned(
              left: clip.start * kPixelsPerSecond,
              width: clip.duration * kPixelsPerSecond,
              top: 0,
              child: CcTappable(
                hoverOpacity: 0.92,
                onTap: onSelect == null ? null : () => onSelect!(timelineKey(track, clip)),
                child: TimelineClipTile(
                  clip: clip,
                  height: track.height,
                  selected: clip.selected || selectedKey == timelineKey(track, clip),
                ),
              ),
            ),
          for (final clip in track.clips)
            if (clip.transitionAfterStart)
              Positioned(
                left: clip.start * kPixelsPerSecond,
                top: 0,
                child: CcTappable(
                  onTap: onSelect == null
                      ? null
                      : () => onSelect!(timelineKey(track, clip, transition: true)),
                  child: TransitionBadge(
                    height: track.height,
                    selected: selectedKey == timelineKey(track, clip, transition: true),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _Playhead extends StatelessWidget {
  const _Playhead();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: CcColors.accent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const Expanded(
          child: SizedBox(width: 2, child: ColoredBox(color: CcColors.accent)),
        ),
      ],
    );
  }
}

/// Two-step nudge shown over the empty lanes of a fresh project.
class _GettingStartedHint extends StatelessWidget {
  const _GettingStartedHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          _HintStep(number: '1', label: 'Import your rushes', active: true),
          SizedBox(width: 10),
          CcIcon(LucideIcons.arrowRight, size: 14, color: CcColors.textTertiary),
          SizedBox(width: 10),
          _HintStep(number: '2', label: 'Drag them onto the timeline', active: false),
        ],
      ),
    );
  }
}

class _HintStep extends StatelessWidget {
  const _HintStep({required this.number, required this.label, required this.active});

  final String number;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brMd,
        border: CcBorders.allStrong,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? CcColors.accent : CcColors.elevated2,
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: CcType.style(
                size: 11,
                weight: CcType.bold,
                color: active ? CcColors.onAccent : CcColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: CcType.style(
              size: 12,
              weight: CcType.medium,
              color: active ? CcColors.textPrimary : CcColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
