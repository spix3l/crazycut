part of 'primitives.dart';

/// App-native multi-line text input. Unlike Material's [TextField], this works
/// directly under CrazyCut's [WidgetsApp] root.
class CcMultilineTextField extends StatefulWidget {
  const CcMultilineTextField({
    super.key,
    required this.controller,
    this.placeholder,
    this.focusNode,
    this.autofocus = false,
    this.minLines = 1,
    this.maxLines = 3,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? placeholder;
  final FocusNode? focusNode;
  final bool autofocus;
  final int minLines;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  @override
  State<CcMultilineTextField> createState() => _CcMultilineTextFieldState();
}

class _CcMultilineTextFieldState extends State<CcMultilineTextField> {
  FocusNode? _ownedFocus;

  FocusNode get _focus => widget.focusNode ?? (_ownedFocus ??= FocusNode());

  @override
  void dispose() {
    _ownedFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = CcType.style(size: 12, color: CcColors.textPrimary);
    return AnimatedBuilder(
      animation: _focus,
      builder: (context, _) => Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: CcDeco.input(focused: _focus.hasFocus),
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) => Stack(
            children: [
              if (value.text.isEmpty && widget.placeholder != null)
                IgnorePointer(
                  child: Text(
                    widget.placeholder!,
                    style: CcType.style(size: 12, color: CcColors.textTertiary),
                  ),
                ),
              EditableText(
                controller: widget.controller,
                focusNode: _focus,
                autofocus: widget.autofocus,
                style: style,
                cursorColor: CcColors.accent,
                backgroundCursorColor: CcColors.elevated2,
                selectionColor: CcColors.accent.withValues(alpha: 0.35),
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                minLines: widget.minLines,
                maxLines: widget.maxLines,
                onTapOutside: (_) =>
                    _focus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild),
                onChanged: widget.onChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
