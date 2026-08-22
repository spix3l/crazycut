import 'package:flutter/widgets.dart' hide Clip;
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/clip_transform.dart';
import '../../../../../state/canvas_geometry.dart';
import '../../../../../data/param_value.dart';
import '../../../../../data/project.dart';
import '../../../../../models/rational.dart';
import '../../../../../state/editor_controller.dart';
import '../../../../../state/timeline_edits.dart';
import 'clip_animation_edge_control.dart';
import 'inspector_effects_tab.dart' show KeyframeDiamond, showKeyframeMenu;

/// Clip animation and built-in transform (FX-9), grouped by consequence rather
/// than presented as one undifferentiated list of controls.
class TransformTab extends StatelessWidget {
  const TransformTab({super.key, required this.controller, required this.clip});

  final EditorController controller;
  final Clip clip;

  EditorController get c => controller;

  @override
  Widget build(BuildContext context) {
    final t = clip.transform ?? ClipTransform();
    final isImage = c.doc.assetById(clip.mediaId)?.type == 'image';
    final isVisualMedia =
        clip.text != null ||
        switch (c.doc.assetById(clip.mediaId)?.type) {
          'image' || 'video' => true,
          _ => false,
        };
    final content = Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isVisualMedia)
            _ClipAnimationSection(
              controller: c,
              clip: clip,
              showContinuousMotion: isImage,
            ),
          _TransformSectionHeader('Layout'),
          _AlignSection(controller: c),
          for (final row in const [
            ('x', 'Position X', -1920.0, 1920.0, 'px'),
            ('y', 'Position Y', -1080.0, 1080.0, 'px'),
            ('scale', 'Scale', 1.0, 400.0, '%'),
            ('rotation', 'Rotation', -180.0, 180.0, '°'),
          ])
            _TransformRow(
              controller: c,
              clip: clip,
              transform: t,
              paramId: row.$1,
              label: row.$2,
              min: row.$3,
              max: row.$4,
              unit: row.$5,
            ),
          _TransformSectionHeader('Appearance'),
          _TransformRow(
            controller: c,
            clip: clip,
            transform: t,
            paramId: 'opacity',
            label: 'Opacity',
            min: 0,
            max: 100,
            unit: '%',
          ),
          if (isImage) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
              child: Row(
                children: [
                  Text(
                    'Flip',
                    style: CcType.style(
                      size: 11,
                      color: CcColors.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  Expanded(
                    child: CcSegmented(
                      expand: true,
                      selectedIndex: (t.flipH ? 1 : 0) + (t.flipV ? 2 : 0),
                      children: [
                        Text('None', style: CcType.nano),
                        Text('H', style: CcType.nano),
                        Text('V', style: CcType.nano),
                        Text('H+V', style: CcType.nano),
                      ],
                      onChanged:
                          (i) => c.setClipTransform(clip.id, (cur) {
                            cur.flipH = i == 1 || i == 3;
                            cur.flipV = i >= 2;
                            return cur;
                          }),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
              child: Row(
                children: [
                  Text(
                    'Framing',
                    style: CcType.style(
                      size: 11,
                      color: CcColors.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  Expanded(
                    child: CcSegmented(
                      expand: true,
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
                      onChanged:
                          (i) => c.setClipTransform(clip.id, (cur) {
                            cur.framing = switch (i) {
                              1 => 'fill',
                              2 => 'stretch',
                              _ => 'fit',
                            };
                            return cur;
                          }),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
    return LayoutBuilder(
      builder:
          (context, constraints) =>
              constraints.hasBoundedHeight
                  ? SingleChildScrollView(child: content)
                  : content,
    );
  }
}

class _TransformSectionHeader extends StatelessWidget {
  const _TransformSectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 18, 14, 8),
    child: CcSectionHeader(label.toUpperCase()),
  );
}

/// Align & distribute (FX-15). Lines the selected images up with each other,
/// or — when only one is selected — with the sequence frame.
///
/// The buttons act on [EditorController.alignableClips], not on the tab's own
/// clip: the inspector keeps showing this tab while several clips are selected,
/// and lining images up is inherently a multi-clip operation.
class _AlignSection extends StatelessWidget {
  const _AlignSection({required this.controller});

  final EditorController controller;

  static const _aligns = [
    (AlignEdge.left, LucideIcons.alignStartVertical, 'Align left'),
    (AlignEdge.centerX, LucideIcons.alignCenterVertical, 'Align centre'),
    (AlignEdge.right, LucideIcons.alignEndVertical, 'Align right'),
    (AlignEdge.top, LucideIcons.alignStartHorizontal, 'Align top'),
    (AlignEdge.centerY, LucideIcons.alignCenterHorizontal, 'Align middle'),
    (AlignEdge.bottom, LucideIcons.alignEndHorizontal, 'Align bottom'),
  ];

  static const _distributes = [
    (
      AlignAxis.horizontal,
      LucideIcons.alignHorizontalDistributeCenter,
      'Distribute horizontally',
    ),
    (
      AlignAxis.vertical,
      LucideIcons.alignVerticalDistributeCenter,
      'Distribute vertically',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final count = c.alignableClips().length;
    // Nothing measurable on the canvas at the playhead — an offline or
    // still-probing asset — so there is nothing to line up.
    if (count == 0) return const SizedBox.shrink();
    final reference = count == 1 ? 'canvas' : 'selection';
    final canDistribute = count >= 3;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Align',
                style: CcType.style(size: 11, color: CcColors.textSecondary),
              ),
              const Spacer(),
              Text('to $reference', style: CcType.nano),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final (edge, icon, label) in _aligns)
                CcTooltip(
                  message: '$label (to $reference)',
                  child: CcIconButton(
                    icon: icon,
                    size: 28,
                    outlined: true,
                    onPressed: () => c.alignClips(edge),
                  ),
                ),
              const Spacer(),
              for (final (axis, icon, label) in _distributes)
                CcTooltip(
                  message:
                      canDistribute
                          ? label
                          : '$label — needs three or more images',
                  child: CcIconButton(
                    icon: icon,
                    size: 28,
                    outlined: true,
                    enabled: canDistribute,
                    onPressed: () => c.distributeClips(axis),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ClipAnimationSection extends StatelessWidget {
  const _ClipAnimationSection({
    required this.controller,
    required this.clip,
    required this.showContinuousMotion,
  });

  final EditorController controller;
  final Clip clip;
  final bool showContinuousMotion;

  bool get _hasAnimation => controller.clipAnimationSpec(clip) != null;

  String? _motion() => controller.clipAnimationPreset(clip, 'motion');

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      decoration: const BoxDecoration(border: CcBorders.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CcSectionHeader(
            'CLIP ANIMATION',
            trailing:
                _hasAnimation
                    ? CcTappable(
                      onTap: () => controller.clearClipAnimation(clip.id),
                      child: Text(
                        'Clear',
                        style: CcType.style(
                          size: 10,
                          weight: CcType.semibold,
                          color: CcColors.accent,
                        ),
                      ),
                    )
                    : null,
          ),
          const SizedBox(height: 6),
          Text(
            'Set how the clip arrives and leaves the frame.',
            style: CcType.style(
              size: 10,
              height: 1.35,
              color: CcColors.textTertiary,
            ),
          ),
          const SizedBox(height: 10),
          ClipAnimationEdgeControl(
            controller: controller,
            clip: clip,
            side: ClipAnimationSide.enter,
          ),
          const SizedBox(height: 8),
          ClipAnimationEdgeControl(
            controller: controller,
            clip: clip,
            side: ClipAnimationSide.leave,
          ),
          if (showContinuousMotion) ...[
            const SizedBox(height: 14),
            Text(
              'CONTINUOUS MOTION',
              style: CcType.style(
                size: 9,
                weight: CcType.semibold,
                color: CcColors.textTertiary,
                letterSpacing: 0.7,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final entry in TimelineEdits.kImagePresets.entries)
                  _PresetChip(
                    label: entry.key,
                    selected: _motion() == entry.value,
                    onTap:
                        () => controller.applyImagePreset(
                          clip.id,
                          _motion() == entry.value ? null : entry.value,
                        ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Container(
        height: 27,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? CcColors.accentDim : CcColors.elevated,
          borderRadius: CcRadius.brSm,
          border: Border.all(
            color: selected ? CcColors.accent : CcColors.border,
          ),
        ),
        child: Text(label, style: CcType.style(size: 10)),
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
  late final TextEditingController _valueController = TextEditingController();
  late final FocusNode _valueFocus = FocusNode(onKeyEvent: _onValueKey);
  bool _editingValue = false;

  @override
  void initState() {
    super.initState();
    _valueFocus.addListener(_onValueFocusChanged);
  }

  @override
  void dispose() {
    _valueFocus
      ..removeListener(_onValueFocusChanged)
      ..dispose();
    _valueController.dispose();
    super.dispose();
  }

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

  String _number(double value) {
    final text = value.toStringAsFixed(2);
    if (text.endsWith('.00')) return text.substring(0, text.length - 3);
    if (text.endsWith('0')) return text.substring(0, text.length - 1);
    return text;
  }

  void _beginValueEdit() {
    _valueController.text = _number(_currentValue);
    setState(() => _editingValue = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_editingValue) return;
      _valueFocus.requestFocus();
      _valueController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _valueController.text.length,
      );
    });
  }

  void _finishValueEdit({required bool commit}) {
    if (!_editingValue) return;
    final raw = _valueController.text
        .trim()
        .toLowerCase()
        .replaceAll(',', '.')
        .replaceAll('px', '')
        .replaceAll('%', '')
        .replaceAll('°', '')
        .trim();
    final parsed = double.tryParse(raw);
    if (commit && parsed != null) {
      widget.controller.setTransformParam(
        widget.clip.id,
        widget.paramId,
        parsed.clamp(widget.min, widget.max),
        at: _localTime,
      );
    }
    setState(() => _editingValue = false);
    _valueFocus.unfocus();
  }

  void _onValueFocusChanged() {
    if (!_valueFocus.hasFocus && _editingValue) {
      _finishValueEdit(commit: true);
    }
  }

  KeyEventResult _onValueKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _finishValueEdit(commit: false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _keyframeMenu(Offset position) => showKeyframeMenu(
    context,
    position,
    controller: widget.controller,
    clip: widget.clip,
    effectInstanceId: '__transform',
    paramId: widget.paramId,
    param: _param(),
    localTime: _localTime,
  );

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
              child: Text(
                widget.label,
                style: CcType.style(size: 11, color: CcColors.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 7,
              child: CcSlider(
                value: ((_currentValue - widget.min) /
                        (widget.max - widget.min))
                    .clamp(0.0, 1.0),
                onChanged:
                    (t) => widget.controller.setTransformParam(
                      widget.clip.id,
                      widget.paramId,
                      widget.min + t * (widget.max - widget.min),
                      at: _localTime,
                    ),
              ),
            ),
            SizedBox(
              width: 62,
              child: _editingValue
                  ? CcTextField(
                      key: ValueKey('transform-value-input-${widget.paramId}'),
                      height: 24,
                      radius: CcRadius.sm,
                      controller: _valueController,
                      focusNode: _valueFocus,
                      onSubmitted: (_) =>
                          _finishValueEdit(commit: true),
                      onTapOutside: (_) => _valueFocus.unfocus(),
                    )
                  : CcTooltip(
                      message: 'Click to type ${widget.label.toLowerCase()}',
                      child: CcTappable(
                        onTap: _beginValueEdit,
                        child: SizedBox(
                          key: ValueKey('transform-value-${widget.paramId}'),
                          height: 28,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              '${_number(_currentValue)}$_unitSuffix',
                              style: CcType.style(
                                size: 10,
                                weight: CcType.medium,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            SizedBox(
              width: 22,
              child: Center(
                child: KeyframeDiamond(
                  animated: _animated,
                  atCurrentTime: _keyAtPlayhead,
                  onTap:
                      () => widget.controller.toggleKeyframe(
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

  String get _unitSuffix => widget.unit;
}
