import 'package:flutter/widgets.dart' hide Clip;

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/project.dart';
import '../../../../../state/editor_controller.dart';
import '../../../../../state/timeline_edits.dart';

/// Shared Enter/Leave editor for a clip-edge animation preset and duration.
class ClipAnimationEdgeControl extends StatelessWidget {
  const ClipAnimationEdgeControl({
    super.key,
    required this.controller,
    required this.clip,
    required this.side,
  });

  final EditorController controller;
  final Clip clip;

  /// Whether this control edits the clip's entry or leave animation.
  final ClipAnimationSide side;

  static const double _maxSeconds = 2;

  String get _sideId => side == ClipAnimationSide.enter ? 'entry' : 'leave';

  String? get _preset => controller.clipAnimationPreset(clip, _sideId);

  String get _label => side == ClipAnimationSide.enter ? 'Enter' : 'Leave';

  String get _helper =>
      side == ClipAnimationSide.enter ? 'At clip start' : 'At clip end';

  String get _valueLabel {
    final id = _preset;
    if (id == null) return 'None';
    return TimelineEdits.kClipEdgePresets.entries
        .firstWhere(
          (entry) => entry.value == id,
          orElse: () => const MapEntry('None', ''),
        )
        .key;
  }

  void _pick(BuildContext context) {
    final anchor = context.findRenderObject() as RenderBox?;
    if (anchor == null || !anchor.attached) return;
    showCcMenu(
      context,
      anchor.localToGlobal(Offset(0, anchor.size.height + 4)),
      [
        CcMenuItem('None', checked: _preset == null, onTap: () => _apply('')),
        for (final entry in TimelineEdits.kClipEdgePresets.entries)
          CcMenuItem(
            entry.key,
            checked: _preset == entry.value,
            separatorBefore: entry.value == 'fade',
            onTap: () => _apply(entry.value),
          ),
      ],
    );
  }

  void _apply(String value) => controller.setClipEntryLeave(
    clip.id,
    entry: side == ClipAnimationSide.enter ? value : null,
    leave: side == ClipAnimationSide.leave ? value : null,
  );

  void _setSeconds(double seconds) => controller.setClipEntryLeave(
    clip.id,
    entry: side == ClipAnimationSide.enter ? (_preset ?? '') : null,
    leave: side == ClipAnimationSide.leave ? (_preset ?? '') : null,
    seconds: seconds,
  );

  @override
  Widget build(BuildContext context) {
    final seconds = controller.clipAnimationSeconds(clip, _sideId);
    final enabled = _preset != null;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brSm,
        border: Border.all(
          color: enabled ? CcColors.accentDim : CcColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                _label,
                style: CcType.style(size: 11, weight: CcType.semibold),
              ),
              const SizedBox(width: 6),
              Text(_helper, style: CcType.micro),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Builder(
                  builder:
                      (anchorContext) => CcDropdown(
                        value: _valueLabel,
                        width: double.infinity,
                        height: 28,
                        fontSize: 11,
                        bordered: true,
                        onTap: () => _pick(anchorContext),
                      ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: CcSlider(
                  value: (seconds / _maxSeconds).clamp(0.0, 1.0),
                  onChanged:
                      enabled
                          ? (value) => _setSeconds(
                            ((value * _maxSeconds) * 20).round() / 20,
                          )
                          : null,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 38,
                child: Text(
                  '${seconds.toStringAsFixed(2)} s',
                  textAlign: TextAlign.right,
                  style: CcType.style(
                    size: 10,
                    weight: CcType.medium,
                    color:
                        enabled
                            ? CcColors.textPrimary
                            : CcColors.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum ClipAnimationSide { enter, leave }
