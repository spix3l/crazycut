import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/project.dart';
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
                'Many effects on one clip — this may reduce playback smoothness.',
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
              builder: (buttonContext) => CcButton(
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
    showCcMenuBelow(context, [
      for (final category in _grouped(catalog).entries)
        ...[
          CcMenuItem(category.key, onTap: null),
          for (final def in category.value)
            CcMenuItem('   ${def['label'] as String}',
                onTap: () => c.addEffect(clip.id, def['id'] as String)),
        ],
    ]);
  }

  Map<String, List<Map<String, dynamic>>> _grouped(
      List<Map<String, dynamic>> catalog) {
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
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapDown: (d) => _menu(context, d.globalPosition),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              child: Row(
                children: [
                  CcCheckbox(
                    checked: enabled,
                    onTap: () => controller.setEffectEnabled(
                        clip.id, instance['id'] as String, !enabled),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_label(type), style: CcType.small),
                  ),
                  CcTappable(
                    onTap: () => _menu(context, Offset(40, 200)),
                    child: const CcIcon(LucideIcons.moreVertical,
                        size: 13, color: CcColors.textSecondary),
                  ),
                ],
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

  void _menu(BuildContext context, Offset at) {
    final id = instance['id'] as String;
    showCcMenu(context, at, [
      CcMenuItem('Move up',
          onTap: () => controller.reorderEffect(clip.id, id,
              _indexOf() - 1),
          checked: null),
      CcMenuItem('Move down',
          onTap: () => controller.reorderEffect(clip.id, id, _indexOf() + 1)),
      CcMenuItem('Reset', onTap: () => controller.resetEffect(clip.id, id)),
      CcMenuItem('Remove',
          danger: true, onTap: () => controller.removeEffect(clip.id, id)),
    ]);
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
  bool get isAnimated {
    final p = widget.param;
    return p is Map && (p['keyframes'] as List?)?.isNotEmpty == true;
  }

  double get staticValue {
    final p = widget.param;
    if (p is num) return p.toDouble();
    if (p is Map) {
      final s = p['static'];
      if (s is num) return s.toDouble();
    }
    return 0;
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
              child: Text(_paramLabel(widget.paramId),
                  style: CcType.style(size: 11, color: CcColors.textSecondary),
                  overflow: TextOverflow.ellipsis),
            ),
            Expanded(
              flex: 7,
              child: CcSlider(
                value:
                    ((staticValue - min) / (max - min)).clamp(0.0, 1.0),
                onChanged: (t) => widget.controller.setEffectParam(
                  widget.clip.id,
                  widget.instanceId,
                  widget.paramId,
                  min + t * (max - min),
                ),
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(staticValue.toStringAsFixed(1),
                  textAlign: TextAlign.right,
                  style: CcType.style(size: 10, weight: CcType.medium)),
            ),
            SizedBox(
              width: 22,
              child: Center(
                child: KeyframeDiamond(
                  animated: isAnimated,
                  atCurrentTime: _keyAtPlayhead(),
                  onTap: () => widget.controller.toggleKeyframe(
                    widget.clip.id,
                    widget.instanceId,
                    widget.paramId,
                    widget.controller.playhead
                        .minus(widget.clip.start),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _keyAtPlayhead() {
    final p = widget.param;
    if (p is! Map) return false;
    final keys = p['keyframes'];
    if (keys is! List) return false;
    final local = widget.controller.playhead.minus(widget.clip.start);
    for (final k in keys) {
      final t = k is Map ? k['t'] : null;
      if (t is String) {
        final parts = t.split('/');
        final secs =
            (num.tryParse(parts[0]) ?? 0) / (num.tryParse(parts[1]) ?? 1);
        if ((secs - local.seconds).abs() < 0.02) return true;
      }
    }
    return false;
  }

  (double, double)? _schemaFor(String typeId, String paramId) {
    for (final def in widget.controller.catalogCache) {
      if (def['id'] != typeId) continue;
      for (final pd in (def['params'] as List)) {
        if ((pd as Map)['id'] == paramId) {
          return (((pd['min'] as num?)?.toDouble()) ?? 0.0,
              ((pd['max'] as num?)?.toDouble()) ?? 100.0);
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
  final ValueChanged<Offset>? onContextMenu;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: onContextMenu == null
          ? null
          : (details) => onContextMenu!(details.globalPosition),
      child: CcTooltip(
        message: atCurrentTime
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
                    color: atCurrentTime
                        ? CcColors.accent
                        : CcColors.elevated2,
                    border: Border.all(
                      color: animated || atCurrentTime
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
    );
  }
}
