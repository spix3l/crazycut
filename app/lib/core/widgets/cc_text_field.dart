part of 'primitives.dart';

/// Read-only text field shell (`Search projects`, `Name`, `Filename`).
class CcTextField extends StatefulWidget {
  const CcTextField({
    super.key,
    this.value,
    this.placeholder,
    this.label,
    this.icon,
    this.trailing,
    this.height = 36,
    this.bordered = true,
    this.radius = CcRadius.md,
    this.controller,
    this.focusNode,
    this.autofocus = false,
    this.onSubmitted,
    this.onTapOutside,
    this.onChanged,
    this.contextMenuBuilder,
  });

  final String? value;
  final String? placeholder;

  /// Persistent label above the field. When supplied, the placeholder is
  /// free to show an example without being the only identity of the input.
  final String? label;
  final IconData? icon;
  final Widget? trailing;
  final double height;
  final bool bordered;
  final double radius;

  /// Supplying a controller turns the field into a real text input; without
  /// one it stays a read-only shell.
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final TapRegionCallback? onTapOutside;
  final EditableTextContextMenuBuilder? contextMenuBuilder;

  @override
  State<CcTextField> createState() => _CcTextFieldState();
}

class _CcTextFieldState extends State<CcTextField> {
  FocusNode? _ownedFocus;

  FocusNode get _focus => widget.focusNode ?? (_ownedFocus ??= FocusNode());

  @override
  void dispose() {
    _ownedFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final controller = widget.controller;
    final height = widget.height;
    final icon = widget.icon;
    final trailing = widget.trailing;
    final hasValue = value != null && value.isNotEmpty;
    final textStyle = CcType.style(
      size: height <= 30 ? 12 : 13,
      color: hasValue || controller != null ? CcColors.textPrimary : CcColors.textTertiary,
    );
    final field = Container(
      height: height,
      padding: EdgeInsets.symmetric(horizontal: icon == null ? 12 : 10),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: BorderRadius.circular(widget.radius),
        border: widget.bordered ? Border.all(color: CcColors.borderStrong) : null,
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            CcIcon(icon, size: height <= 30 ? 13 : 14, color: CcColors.textTertiary),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: controller != null
                ? MouseRegion(
                  cursor: SystemMouseCursors.text,
                  child: EditableText(
                    controller: controller,
                    focusNode: _focus,
                    autofocus: widget.autofocus,
                    style: textStyle,
                    cursorColor: CcColors.accent,
                    backgroundCursorColor: CcColors.elevated2,
                    selectionColor: CcColors.accent.withValues(alpha: 0.35),
                    showCursor: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableInteractiveSelection: true,
                    keyboardType: TextInputType.text,
                    onSubmitted: widget.onSubmitted,
                    onChanged: widget.onChanged,
                    onTapOutside: widget.onTapOutside,
                    maxLines: 1,
                    contextMenuBuilder: widget.contextMenuBuilder,
                  ),
                )
                : Text(
                    hasValue ? value : (widget.placeholder ?? ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textStyle,
                  ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
    final label = widget.label;
    if (label == null) return field;
    // Persistent label above the field: the input keeps its identity even
    // when the placeholder scrolls away or is cleared (interaction rule:
    // placeholders are examples, not labels).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(label, style: CcType.small.copyWith(color: CcColors.textSecondary)),
        ),
        field,
      ],
    );
  }
}
