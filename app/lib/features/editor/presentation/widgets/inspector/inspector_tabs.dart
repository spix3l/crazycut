import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/project.dart';
import '../../../../../models/rational.dart';
import '../../../../../state/editor_controller.dart';
import 'inspector_rows.dart';

/// Frame-exact timing for the selected clip (TIM-8). Every field commits one
/// undoable edit, so typing a start is identical to dragging it.
class ClipTimingTab extends StatelessWidget {
  const ClipTimingTab({super.key, required this.controller, required this.clip});

  final EditorController controller;
  final Clip clip;

  @override
  Widget build(BuildContext context) {
    final fps = controller.fps;
    final asset = controller.doc.assetById(clip.mediaId);
    final track = controller.doc.trackById(clip.trackId);
    final locked = track?.lock ?? false;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: CcSectionHeader('TIMING'),
          ),
          TimecodeRow(
            label: 'Start',
            value: clip.start,
            fps: fps,
            enabled: !locked,
            onSubmitted: (value) => controller.setClipTiming(clip.id, start: value),
          ),
          TimecodeRow(
            label: 'Duration',
            value: clip.duration,
            fps: fps,
            enabled: !locked,
            onSubmitted: (value) => controller.setClipTiming(clip.id, duration: value),
          ),
          TimecodeRow(
            label: 'End',
            value: clip.end,
            fps: fps,
            enabled: !locked,
            onSubmitted: (value) =>
                controller.setClipTiming(clip.id, duration: value.minus(clip.start)),
          ),
          TimecodeRow(
            label: 'Source in',
            value: clip.sourceIn,
            fps: fps,
            enabled: !locked,
            onSubmitted: (value) => controller.setClipTiming(clip.id, sourceIn: value),
          ),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: CcSectionHeader('SOURCE'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Column(
              children: [
                InfoRow('Media', _value(asset?.name ?? 'missing')),
                InfoRow(
                  'Speed',
                  _speedControl(controller, clip, locked),
                ),
                InfoRow('Track', _value(track?.name ?? '—')),
                if (asset != null)
                  InfoRow('Available', _value(Rt.toTimecode(asset.duration, fps))),
                InfoRow('Handles', _value(_handles(asset, fps))),
                InfoRow('Linked', _value(clip.linkedGroup == null ? 'no' : 'A/V')),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Expanded(
                  child: CcButton(
                    label: 'Split here',
                    kind: CcButtonKind.secondary,
                    height: 30,
                    radius: CcRadius.sm,
                    onPressed: controller.splitAtPlayhead,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: CcButton(
                    label: clip.linkedGroup == null ? 'Link' : 'Unlink',
                    kind: CcButtonKind.secondary,
                    height: 30,
                    radius: CcRadius.sm,
                    onPressed: clip.linkedGroup == null
                        ? (controller.selection.length > 1 ? controller.linkSelection : null)
                        : controller.unlinkSelection,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _value(String text) =>
      Text(text, style: CcType.style(size: 12, weight: CcType.medium));

  static Widget _speedControl(
    EditorController controller,
    Clip clip,
    bool locked,
  ) {
    final next = controller.nextClipSpeedLabel(clip.id);
    final canIncrease = next != null &&
        !locked &&
        controller.doc.linkedWith(clip).every(
          (candidate) => !(controller.doc.trackById(candidate.trackId)?.lock ?? false),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_speedLabel(clip.speedValue), style: CcType.style(size: 12, weight: CcType.medium)),
        const SizedBox(width: 8),
        CcTooltip(
          message: canIncrease
              ? 'Increase speed to $next'
              : next == null
              ? 'Maximum speed reached'
              : 'Unlock linked tracks to change speed',
          child: CcIconButton(
            icon: LucideIcons.forward,
            size: 24,
            iconSize: 12,
            enabled: canIncrease,
            onPressed: canIncrease ? () => controller.increaseClipSpeed(clip.id) : null,
          ),
        ),
      ],
    );
  }

  static String _speedLabel(double speed) {
    final text = speed == speed.roundToDouble()
        ? speed.round().toString()
        : speed.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
    return '${text}x';
  }

  String _handles(MediaAsset? asset, double fps) {
    if (asset == null || asset.duration.isZero) return 'unbounded';
    final head = clip.sourceIn;
    final tail = asset.duration.minus(clip.sourceIn.plus(clip.sourceSpan));
    return '−${Rt.toTimecode(head, fps).substring(3)} / '
        '+${Rt.toTimecode(tail < Rt.zero() ? Rt.zero() : tail, fps).substring(3)}';
  }
}

/// Gain, pan, mute and fades. The mixer panel itself is M3; these are the
/// per-clip fields the document already carries.
