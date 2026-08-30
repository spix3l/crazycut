import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/param_value.dart';
import '../../../../../data/project.dart';
import '../../../../../models/rational.dart';
import '../../../../../state/editor_controller.dart';

/// The per-clip effect stack (FX-1..4): ordered list, enable/disable,
/// reorder via menu, reset, remove, and an "Add effect" gallery grouped by
/// category. Param rows render from the effect's schema; every animatable row
/// ends in a keyframe diamond (KEY-4).
class EffectsTab extends StatelessWidget {
  const EffectsTab({super.key, required this.controller, required this.clip});

  final EditorController controller;
  final Clip clip;

  EditorController get c => controller;

  @override
  Widget build(BuildContext context) {
    final overloaded = c.selectionOverloaded;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (overloaded)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                'Many effects on one clip. This may reduce playback smoothness.',
                style: CcType.nano,
              ),
            ),
          for (final effect in clip.effects)
            _EffectCard(
              controller: c,
              clip: clip,
              instance: effect as Map<String, dynamic>,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Builder(
              builder:
                  (buttonContext) => CcButton(
                    label: 'Add effect',
                    icon: LucideIcons.plus,
                    onPressed: () => _openGallery(buttonContext),
                  ),
            ),
          ),
        ],
      ),
    );
  }

  void _openGallery(BuildContext context) async {
    final catalog = await c.effectCatalogOrFallback();
    if (!context.mounted) return;
    showCcMenu(context, [
      for (final category in _grouped(catalog).entries) ...[
        CcMenuItem(category.key, onTap: null),
        for (final def in category.value)
          CcMenuItem(
            '   ${def['label'] as String}',
            onTap: () => c.addEffect(clip.id, def['id'] as String),
          ),
      ],
    ]);
  }

  Map<String, List<Map<String, dynamic>>> _grouped(
    List<Map<String, dynamic>> catalog,
  ) {
    final out = <String, List<Map<String, dynamic>>>{};
    for (final def in catalog) {
      out.putIfAbsent(def['category'] as String? ?? 'Other', () => []).add(def);
    }
    return out;
  }
}

class _EffectCard extends StatelessWidget {
  const _EffectCard({
    required this.controller,
    required this.clip,
    required this.instance,
  });

  final EditorController controller;
  final Clip clip;
  final Map<String, dynamic> instance;

  @override
  Widget build(BuildContext context) {
    final enabled = (instance['enabled'] as bool?) ?? true;
    final type = instance['type'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: CcColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Builder(
            builder:
                (headerContext) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onSecondaryTapDown: (_) => _menu(headerContext),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                    child: Row(
                      children: [
                        CcCheckbox(
                          checked: enabled,
                          onTap:
                              () => controller.setEffectEnabled(
                                clip.id,
                                instance['id'] as String,
                                !enabled,
                              ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_label(type), style: CcType.small),
                        ),
                        Builder(
                          builder:
                              (buttonContext) => CcTappable(
                                onTap:
                                    () => showCcMenu(
                                      buttonContext,
                                      _items(),
                                    ),
                                child: const CcIcon(
                                  LucideIcons.moreVertical,
                                  size: 13,
                                  color: CcColors.textSecondary,
                                ),
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
          ),
          for (final entry
              in ((instance['params'] as Map<String, dynamic>?) ?? const {})
                  .entries)
            _ParamRow(
              controller: controller,
              clip: clip,
              instanceId: instance['id'] as String,
              paramId: entry.key,
              param: entry.value,
            ),
        ],
      ),
    );
  }

  void _menu(BuildContext anchorContext) =>
      showCcMenu(anchorContext, _items());

  List<CcMenuItem> _items() {
    final id = instance['id'] as String;
    return [
      CcMenuItem(
        'Move up',
        onTap: () => controller.reorderEffect(clip.id, id, _indexOf() - 1),
        checked: null,
      ),
      CcMenuItem(
        'Move down',
        onTap: () => controller.reorderEffect(clip.id, id, _indexOf() + 1),
      ),
      CcMenuItem('Reset', onTap: () => controller.resetEffect(clip.id, id)),
      CcMenuItem(
        'Remove',
        danger: true,
        onTap: () => controller.removeEffect(clip.id, id),
      ),
    ];
  }

  int _indexOf() =>
      clip.effects.indexWhere((e) => (e as Map)['id'] == instance['id']);

  String _label(String typeId) {
    for (final def in controller.catalogCache) {
      if (def['id'] == typeId) return def['label'] as String? ?? typeId;
    }
    return typeId;
  }
}

/// One parameter row: label · slider · value · ◆.
class _ParamRow extends StatefulWidget {
  const _ParamRow({
    required this.controller,
    required this.clip,
    required this.instanceId,
    required this.paramId,
    required this.param,
  });

  final EditorController controller;
  final Clip clip;
  final String instanceId;
  final String paramId;
  final dynamic param;

  @override
  State<_ParamRow> createState() => _ParamRowState();
}

class _ParamRowState extends State<_ParamRow> {
  ParamValue get _param {
    final p = widget.param;
    return p is num ? ParamValue.staticNum(p.toDouble()) : ParamValue.from(p);
  }

  bool get isAnimated => _param.animated;

  Rt get _localTime => widget.controller.playhead
      .minus(widget.clip.start)
      .clampTo(Rt.zero(), widget.clip.duration);

  /// What the parameter is worth *right now* — the animated value under the
  /// playhead, not the resting static. Showing the static on an animated row
  /// meant the slider sat still while the picture moved, and dragging it
  /// edited a value nothing was reading.
  double get currentValue {
    final v = _param.evaluate(_localTime);
    return v is num ? v.toDouble() : 0;
  }

  @override
  Widget build(BuildContext context) {
    // Only numeric params get sliders in v1; point/color params are edited
    // numerically later (blur-island centre etc.).
    final p = widget.param;
    final numeric = p is num || (p is Map && p['static'] is num);
    if (!numeric) return const SizedBox.shrink();

    final schema = _schemaFor(widget.instanceId, widget.paramId);
    final min = schema?.$1 ?? 0.0;
    final max = schema?.$2 ?? 100.0;

    return SizedBox(
      height: 28,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Expanded(
              flex: 5,
              child: Text(
                _paramLabel(widget.paramId),
                style: CcType.style(size: 11, color: CcColors.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 7,
              child: CcSlider(
                value: ((currentValue - min) / (max - min)).clamp(0.0, 1.0),
                onChanged: (t) => _setValue(min + t * (max - min)),
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                currentValue.toStringAsFixed(1),
                textAlign: TextAlign.right,
                style: CcType.style(size: 10, weight: CcType.medium),
              ),
            ),
            SizedBox(
              width: 22,
              child: Center(
                child: KeyframeDiamond(
                  animated: isAnimated,
                  atCurrentTime: _keyAtPlayhead(),
                  onTap:
                      () => widget.controller.toggleKeyframe(
                        widget.clip.id,
                        widget.instanceId,
                        widget.paramId,
                        widget.controller.playhead.minus(widget.clip.start),
                      ),
                  onContextMenu:
                      (anchor) => showKeyframeMenu(
                        anchor,
                        controller: widget.controller,
                        clip: widget.clip,
                        effectInstanceId: widget.instanceId,
                        paramId: widget.paramId,
                        param: _param,
                        localTime: _localTime,
                      ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// An animated parameter writes to the key under the playhead (creating one
  /// if the drag started between keys); a static one keeps editing its static.
  void _setValue(double value) {
    if (isAnimated) {
      widget.controller.setKeyframeValue(
        widget.clip.id,
        widget.instanceId,
        widget.paramId,
        _localTime,
        value,
      );
      return;
    }
    widget.controller.setEffectParam(
      widget.clip.id,
      widget.instanceId,
      widget.paramId,
      value,
    );
  }

  bool _keyAtPlayhead() => _param.keyframes.any(
    (key) =>
        (ParamValue.timeOf(key) - _localTime).micros.abs() <=
        widget.controller.frameDuration.micros ~/ 2,
  );

  (double, double)? _schemaFor(String typeId, String paramId) {
    for (final def in widget.controller.catalogCache) {
      if (def['id'] != typeId) continue;
      for (final pd in (def['params'] as List)) {
        if ((pd as Map)['id'] == paramId) {
          return (
            ((pd['min'] as num?)?.toDouble()) ?? 0.0,
            ((pd['max'] as num?)?.toDouble()) ?? 100.0,
          );
        }
      }
    }
    return null;
  }

  String _paramLabel(String id) => switch (id) {
    'amount' => 'Amount',
    'stops' => 'Stops',
    'radius' => 'Radius',
    'cell' => 'Cell size',
    'iterations' => 'Quality',
    'roundness' => 'Roundness',
    'softness' => 'Softness',
    'centerX' => 'Center X',
    'centerY' => 'Center Y',
    'size' => 'Size',
    'aspect' => 'Aspect',
    'feather' => 'Feather',
    'left' => 'Left',
    'right' => 'Right',
    'top' => 'Top',
    'bottom' => 'Bottom',
    'offsetX' => 'Offset X',
    'offsetY' => 'Offset Y',
    'blur' => 'Blur',
    'opacity' => 'Opacity',
    _ => id,
  };
}

/// The options behind a right-click on any keyframe diamond (KEY-7).
///
/// Both the transform rows and the effect rows show this: a keyframe that can
/// only be created and never removed is a trap, and the diamond alone gives no
/// way to walk between the keys already on the parameter.
void showKeyframeMenu(
  BuildContext anchorContext, {
  required EditorController controller,
  required Clip clip,
  required String effectInstanceId,
  required String paramId,
  required ParamValue param,
  required Rt localTime,
}) {
  final times =
      param.keyframes.map(ParamValue.timeOf).toList()
        ..sort((a, b) => a.compareTo(b));
  final previous = times.where((time) => time < localTime).lastOrNull;
  final next = times.where((time) => time > localTime).firstOrNull;
  final atPlayhead = times.any(
    (time) =>
        (time - localTime).micros.abs() <= controller.frameDuration.micros ~/ 2,
  );
  showCcMenu(anchorContext, [
    CcMenuItem(
      'Previous keyframe',
      icon: LucideIcons.chevronLeft,
      onTap:
          previous == null
              ? null
              : () => controller.seekTo(clip.start.plus(previous)),
    ),
    CcMenuItem(
      'Next keyframe',
      icon: LucideIcons.chevronRight,
      onTap:
          next == null ? null : () => controller.seekTo(clip.start.plus(next)),
    ),
    CcMenuItem(
      'Delete keyframe',
      icon: LucideIcons.trash2,
      separatorBefore: true,
      onTap:
          !atPlayhead
              ? null
              : () => controller.removeKeyframe(
                clip.id,
                effectInstanceId,
                paramId,
                localTime,
              ),
    ),
    CcMenuItem(
      'Clear all keyframes',
      danger: true,
      onTap:
          !param.animated
              ? null
              : () =>
                  controller.clearKeyframes(clip.id, effectInstanceId, paramId),
    ),
  ]);
}

/// The ◆ toggle (KEY-4).
class KeyframeDiamond extends StatelessWidget {
  const KeyframeDiamond({
    super.key,
    required this.animated,
    required this.atCurrentTime,
    this.onTap,
    this.onContextMenu,
  });

  final bool animated;
  final bool atCurrentTime;
  final VoidCallback? onTap;

  /// Anchors the right-click menu to the diamond itself.
  final ValueChanged<BuildContext>? onContextMenu;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder:
          (diamondContext) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapDown:
                onContextMenu == null
                    ? null
                    : (_) => onContextMenu!(diamondContext),
            child: CcTooltip(
              message:
                  atCurrentTime
                      ? 'Keyframe at playhead · right-click for options'
                      : animated
                      ? 'Animated · click to add a keyframe here'
                      : 'Add keyframe at playhead',
              child: CcTappable(
                onTap: onTap,
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: Center(
                    child: Transform.rotate(
                      angle: 3.14159 / 4,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color:
                              atCurrentTime
                                  ? CcColors.accent
                                  : CcColors.elevated2,
                          border: Border.all(
                            color:
                                animated || atCurrentTime
                                    ? CcColors.accent
                                    : CcColors.borderStrong,
                          ),
                          borderRadius: BorderRadius.circular(1.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
    );
  }
}
