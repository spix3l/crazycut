part of 'inspector_rows.dart';

/// Label · slider · value row (kept from the design for percentage controls).
///
/// The value is click-to-type whenever [onCommitText] is supplied: it renders
/// as plain text and swaps in a small field on tap (Enter or focus loss
/// commits, Escape cancels). Callers pass [editText] as the raw number shown
/// in the field and parse the raw typed string in [onCommitText], so each
/// domain keeps its own units while the interaction stays identical.
class SliderRow extends StatelessWidget {
  const SliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.display,
    this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.labelWidth = 78,
    this.editText,
    this.onCommitText,
    this.editTooltip,
  });

  final String label;

  /// 0..1 slider position.
  final double value;
  final String display;
  final ValueChanged<double>? onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;
  final double labelWidth;

  /// Raw text loaded into the field when editing starts (`12`, `3.5`).
  /// Editing is enabled when both this and [onCommitText] are supplied.
  final String? editText;

  /// Receives the raw typed text on commit. Null keeps the value read-only.
  final ValueChanged<String>? onCommitText;

  /// Hover hint for the value. Defaults to `Click to type <label>`.
  final String? editTooltip;

  @override
  Widget build(BuildContext context) {
    final commit = onCommitText;
    final editable =
        commit != null && editText != null && onChanged != null;
    return SizedBox(
      height: 32,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            SizedBox(
              width: labelWidth,
              child: Text(label, style: CcType.small),
            ),
            Expanded(
              child: CcSlider(
                value: value.clamp(0, 1),
                onChanged: onChanged,
                onChangeStart: onChangeStart,
                onChangeEnd: onChangeEnd,
              ),
            ),
            const SizedBox(width: 10),
            editable
                ? CcEditableValue(
                  display: display,
                  editText: editText!,
                  onCommit: commit,
                  tooltip:
                      editTooltip ?? 'Click to type ${label.toLowerCase()}',
                  width: 44,
                  height: 28,
                )
                : SizedBox(
                  width: 44,
                  child: Text(
                    display,
                    textAlign: TextAlign.right,
                    style: CcType.style(
                      size: 11,
                      weight: CcType.medium,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
