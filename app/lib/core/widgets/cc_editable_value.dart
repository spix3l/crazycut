part of 'primitives.dart';

/// Click-to-type numeric value shown next to a slider.
///
/// Standardizes the pattern first introduced by the transform rows: the value
/// reads as plain text, clicking (or focusing with Enter/Space) swaps in a
/// small [CcTextField] with the current number selected, Enter or focus loss
/// commits, Escape cancels.
///
/// The widget owns its editing state (controller, focus, commit/cancel), so
/// parents stay stateless. Parsing stays with the caller through [onCommit],
/// which receives the raw typed text, because each domain speaks its own
/// units (dB, pan L/R, %, px, seconds).
class CcEditableValue extends StatefulWidget {
  const CcEditableValue({
    super.key,
    required this.display,
    required this.editText,
    required this.onCommit,
    this.tooltip,
    this.enabled = true,
    this.width = 62,
    this.height = 28,
    this.inputHeight = 24,
    this.style,
    this.displayKey,
    this.fieldKey,
  });

  /// Formatted text shown when idle (for example `125%`, `+3.5`, `0.50 s`).
  final String display;

  /// Raw text loaded into the field when editing starts (`125`, `3.5`).
  final String editText;

  /// Receives the raw typed text on commit (Enter or focus loss).
  final ValueChanged<String> onCommit;

  /// Hover and accessibility hint. Defaults to a generic prompt.
  final String? tooltip;

  /// When false, renders plain text with no tap affordance.
  final bool enabled;

  final double width;
  final double height;
  final double inputHeight;
  final TextStyle? style;

  /// Keys forwarded to the idle display and the editing field, so existing
  /// widget tests can keep finding `transform-value-*` style keys.
  final Key? displayKey;
  final Key? fieldKey;

  @override
  State<CcEditableValue> createState() => _CcEditableValueState();
}

class _CcEditableValueState extends State<CcEditableValue> {
  late final TextEditingController _controller = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _begin() {
    if (!widget.enabled || _editing) return;
    _controller.text = widget.editText;
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_editing) return;
      _focus.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  void _finish({required bool commit}) {
    if (!_editing) return;
    final raw = _controller.text;
    setState(() => _editing = false);
    _focus.unfocus();
    if (commit) widget.onCommit(raw);
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus && _editing) _finish(commit: true);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _finish(commit: false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  TextStyle get _displayStyle =>
      widget.style ??
      CcType.style(
        size: 11,
        weight: CcType.medium,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child:
          _editing
              ? CcTextField(
                key: widget.fieldKey,
                height: widget.inputHeight,
                radius: CcRadius.sm,
                controller: _controller,
                focusNode: _focus,
                onSubmitted: (_) => _finish(commit: true),
                onTapOutside: (_) => _focus.unfocus(),
              )
              : widget.enabled
              ? CcTooltip(
                message: widget.tooltip ?? 'Click to type a value',
                child: CcTappable(
                  onTap: _begin,
                  child: SizedBox(
                    key: widget.displayKey,
                    height: widget.height,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        widget.display,
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                        style: _displayStyle,
                      ),
                    ),
                  ),
                ),
              )
              : SizedBox(
                key: widget.displayKey,
                height: widget.height,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    widget.display,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: _displayStyle.copyWith(
                      color:
                          _displayStyle.color ??
                          CcColors.textPrimary.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
    );
  }
}

/// Shared loose-number parsing for typed slider values.
///
/// Accepts a decimal comma (`1,5`), either minus sign (`-`/`-`), and strips
/// the common slider suffixes (`px`, `%`, `deg`, the degree sign, `s`, the
/// multiplication sign) so typing `125%` or `45 deg` just works. Returns null
/// when nothing numeric remains; callers clamp to their own range.
double? parseCcDouble(String raw) {
  var text =
      raw.trim().toLowerCase().replaceAll(',', '.').replaceAll('\u2212', '-');
  if (text.isEmpty) return null;
  for (final suffix in ['px', 'deg', '%', '\u00b0', 's', '\u00d7', 'x']) {
    if (text.endsWith(suffix)) {
      text = text.substring(0, text.length - suffix.length).trim();
    }
  }
  if (text.isEmpty) return null;
  return double.tryParse(text);
}

/// Parses a typed decibel value. Accepts `-inf`, `-infinity`, and the
/// infinity symbol for the bottom of the fader; otherwise falls back to
/// [parseCcDouble] with an optional `db` suffix.
double? parseCcDb(String raw) {
  final text =
      raw.trim().toLowerCase().replaceAll(',', '.').replaceAll('\u2212', '-');
  if (text.isEmpty) return null;
  if (text == '-inf' ||
      text == '-infinity' ||
      text == '-\u221e' ||
      text == '\u221e' ||
      text == 'inf') {
    return double.negativeInfinity;
  }
  var stripped = text;
  if (stripped.endsWith('db')) {
    stripped = stripped.substring(0, stripped.length - 2).trim();
  }
  return parseCcDouble(stripped);
}

/// Parses a typed stereo pan. Accepts `C`/`center` for middle, an `L`/`R`
/// prefix (`L50`, `R30`), a -100..100 percent, or a -1..1 fraction. Values
/// with magnitude above 1 are read as percent, so both `50` and `0.5` mean
/// half right. Returns null when unparseable.
double? parseCcPan(String raw) {
  var text =
      raw.trim().toLowerCase().replaceAll(',', '.').replaceAll('\u2212', '-');
  if (text.isEmpty) return null;
  if (text == 'c' || text == 'center' || text == 'centre') return 0;
  var sign = 1.0;
  if (text.startsWith('l')) {
    sign = -1;
    text = text.substring(1).trim();
  } else if (text.startsWith('r')) {
    text = text.substring(1).trim();
  }
  final parsed = double.tryParse(text);
  if (parsed == null) return null;
  final scaled = parsed.abs() > 1 ? parsed / 100 : parsed;
  return (sign * scaled).clamp(-1.0, 1.0);
}
