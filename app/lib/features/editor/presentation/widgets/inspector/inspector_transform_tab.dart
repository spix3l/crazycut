import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/clip_transform.dart';
import '../../../../../data/param_value.dart';
import '../../../../../data/project.dart';
import '../../../../../models/rational.dart';
import '../../../../../state/editor_controller.dart';
import '../../../../../state/timeline_edits.dart';
import 'inspector_effects_tab.dart' show KeyframeDiamond;

/// Built-in transform (FX-9): position, scale, rotation, anchor, opacity,
/// flips and framing — every animatable row with a keyframe diamond (KEY-4).
class TransformTab extends StatelessWidget {
  const TransformTab({super.key, required this.controller, required this.clip});

  final EditorController controller;
  final Clip clip;

  EditorController get c => controller;

  static const _rows = [
    ('x', 'Position X', -1920.0, 1920.0, 'px'),
    ('y', 'Position Y', -1080.0, 1080.0, 'px'),
    ('scale', 'Scale', 1.0, 400.0, '%'),
    ('rotation', 'Rotation', -180.0, 180.0, '°'),
    ('opacity', 'Opacity', 0.0, 100.0, '%'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = clip.transform ?? ClipTransform();
    final isImage = c.doc.assetById(clip.mediaId)?.type == 'image';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isImage) ...[
            _ImageAnimationSection(controller: c, clip: clip, transform: t),
            const SizedBox(height: 10),
          ],
          for (final (id, label, min, max, unit) in _rows)
            _TransformRow(
              controller: c,
              clip: clip,
              transform: t,
              paramId: id,
              label: label,
              min: min,
              max: max,
              unit: unit,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
            child: Row(
              children: [
                Text('Flip',
                    style: CcType.style(size: 11, color: CcColors.textSecondary)),
                const Spacer(),
                CcSegmented(
                  selectedIndex: (t.flipH ? 1 : 0) + (t.flipV ? 2 : 0),
                  children: [
                    Text('None', style: CcType.nano),
                    Text('H', style: CcType.nano),
                    Text('V', style: CcType.nano),
                    Text('H+V', style: CcType.nano),
                  ],
                  onChanged: (i) => c.setClipTransform(clip.id, (cur) {
                    cur.flipH = i == 1 || i == 3;
                    cur.flipV = i >= 2;
                    return cur;
                  }),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
            child: Row(
              children: [
                Text('Framing',
                    style: CcType.style(size: 11, color: CcColors.textSecondary)),
                const Spacer(),
                CcSegmented(
                  selectedIndex: switch (t.framing) {
                    'fill' => 1,
                    'stretch' => 2,
                    _ => 0,
                  },
                  children: [
                    Text('Fit', style: CcType.nano),
                    Text('Fill', style: CcType.nano),
                    Text('Stretch', style: CcType.nano),
                  ],
                  onChanged: (i) => c.setClipTransform(clip.id, (cur) {
                    cur.framing = switch (i) { 1 => 'fill', 2 => 'stretch', _ => 'fit' };
                    return cur;
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageAnimationSection extends StatelessWidget {
  const _ImageAnimationSection({
    required this.controller,
    required this.clip,
    required this.transform,
  });

  final EditorController controller;
  final Clip clip;
  final ClipTransform transform;

  bool get _hasMotion =>
      transform.x.animated || transform.y.animated || transform.scale.animated;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CcSectionHeader(
            'ANIMATION',
            trailing: _hasMotion
                ? CcTappable(
                    onTap: () => controller.clearImageAnimation(clip.id),
                    child: Text('Clear', style: CcType.style(
                      size: 10,
                      weight: CcType.semibold,
                      color: CcColors.accent,
                    )),
                  )
                : null,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final preset in TimelineEdits.kImagePresets.keys)
                CcTappable(
                  onTap: () => controller.applyImagePreset(
                    clip.id,
                    TimelineEdits.kImagePresets[preset]!,
                  ),
                  child: Container(
                    height: 27,
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: CcColors.elevated,
                      borderRadius: CcRadius.brSm,
                      border: Border.all(color: CcColors.border),
                    ),
                    child: Text(preset, style: CcType.style(size: 10)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TransformRow extends StatefulWidget {
  const _TransformRow({
    required this.controller,
    required this.clip,
    required this.transform,
    required this.paramId,
    required this.label,
    required this.min,
    required this.max,
    required this.unit,
  });

  final EditorController controller;
  final Clip clip;
  final ClipTransform transform;
  final String paramId;
  final String label;
  final double min;
  final double max;
  final String unit;

  @override
  State<_TransformRow> createState() => _TransformRowState();
}

class _TransformRowState extends State<_TransformRow> {
  ParamValue _param() => switch (widget.paramId) {
        'x' => widget.transform.x,
        'y' => widget.transform.y,
        'scale' => widget.transform.scale,
        'rotation' => widget.transform.rotation,
        _ => widget.transform.opacity,
      };

  bool get _animated => _param().animated;

  Rt get _localTime => widget.controller.playhead
      .minus(widget.clip.start)
      .clampTo(Rt.zero(), widget.clip.duration);

  bool get _keyAtPlayhead => _param().keyframes.any(
        (key) =>
            (ParamValue.timeOf(key) - _localTime).micros.abs() <=
            widget.controller.frameDuration.micros ~/ 2,
      );

  double get _currentValue {
    final v = _param().evaluate(_localTime);
    return v is num ? v.toDouble() : widget.min;
  }

  void _keyframeMenu(Offset position) {
    final times = _param().keyframes.map(ParamValue.timeOf).toList()
      ..sort((a, b) => a.compareTo(b));
    final before = times.where((time) => time < _localTime).toList();
    final after = times.where((time) => time > _localTime).toList();
    final previous = before.isEmpty ? null : before.last;
    final next = after.isEmpty ? null : after.first;
    showCcMenu(context, position, [
      CcMenuItem(
        'Previous keyframe',
        icon: LucideIcons.chevronLeft,
        onTap: previous == null
            ? null
            : () => widget.controller.seekTo(widget.clip.start.plus(previous)),
      ),
      CcMenuItem(
        'Next keyframe',
        icon: LucideIcons.chevronRight,
        onTap: next == null
            ? null
            : () => widget.controller.seekTo(widget.clip.start.plus(next)),
      ),
      CcMenuItem(
        'Delete keyframe',
        icon: LucideIcons.trash2,
        separatorBefore: true,
        onTap: !_keyAtPlayhead
            ? null
            : () => widget.controller.removeKeyframe(
                  widget.clip.id,
                  '__transform',
                  widget.paramId,
                  _localTime,
                ),
      ),
      CcMenuItem(
        'Clear all keyframes',
        danger: true,
        onTap: !_animated
            ? null
            : () => widget.controller.clearKeyframes(
                  widget.clip.id,
                  '__transform',
                  widget.paramId,
                ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Expanded(
              flex: 5,
              child: Text(widget.label,
                  style: CcType.style(size: 11, color: CcColors.textSecondary),
                  overflow: TextOverflow.ellipsis),
            ),
            Expanded(
              flex: 7,
              child: CcSlider(
                value:
                    ((_currentValue - widget.min) / (widget.max - widget.min))
                        .clamp(0.0, 1.0),
                onChanged: (t) => widget.controller.setTransformParam(
                  widget.clip.id,
                  widget.paramId,
                  widget.min + t * (widget.max - widget.min),
                  at: _localTime,
                ),
              ),
            ),
            SizedBox(
              width: 46,
              child: Text(
                '${_currentValue.toStringAsFixed(_currentValue.abs() < 10 && _currentValue % 1 != 0 ? 1 : 0)}$_unitSuffix',
                textAlign: TextAlign.right,
                style: CcType.style(size: 10, weight: CcType.medium),
              ),
            ),
            SizedBox(
              width: 22,
              child: Center(
                child: KeyframeDiamond(
                  animated: _animated,
                  atCurrentTime: _keyAtPlayhead,
                  onTap: () => widget.controller.toggleKeyframe(
                    widget.clip.id,
                    '__transform',
                    widget.paramId,
                    widget.controller.playhead.minus(widget.clip.start),
                  ),
                  onContextMenu: _keyframeMenu,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _unitSuffix => widget.paramId == 'rotation' ? '°' : '';
}
