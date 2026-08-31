part of 'primitives.dart';

/// Pointer affordance + press feedback without pulling in Material's `InkWell`.
///
/// Focus is architecture here: every tappable is focusable, activates on
/// Enter/Space, and shows a 2 px accent focus ring so keyboard users get the
/// same map mouse users get (UIX-3).
class CcTappable extends StatefulWidget {
  const CcTappable({
    super.key,
    required this.child,
    this.onTap,
    this.onDoubleTap,
    this.cursor = SystemMouseCursors.click,
    this.hoverOpacity = 0.82,
    this.pressedOpacity = 0.65,
    this.autofocus = false,
    this.builder,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// Optional second gesture on the same surface — rename-in-place, mostly.
  /// Supplying it makes taps wait for the double-tap window, so it is left off
  /// wherever the tap must feel immediate.
  final VoidCallback? onDoubleTap;

  final MouseCursor cursor;
  final double hoverOpacity;
  final double pressedOpacity;

  /// Requests focus when the widget mounts. Used by menu rows so a keyboard
  /// user lands on the first item the moment the menu opens (UIX-3).
  final bool autofocus;

  /// Optional hover-aware builder; when given it wins over the opacity fade.
  final Widget Function(BuildContext context, bool hovered, Widget child)? builder;

  @override
  State<CcTappable> createState() => _CcTappableState();
}

class _CcTappableState extends State<CcTappable> {
  final FocusNode _focus = FocusNode();
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      final hasFocus = _focus.hasFocus;
      if (hasFocus != _focused) setState(() => _focused = hasFocus);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Enter and Space activate; arrow keys move focus through the widget's
    // siblings so grouped controls (toolbar, tabs, menu rows) are navigable.
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
      case LogicalKeyboardKey.space:
        final action = widget.onTap;
        if (action != null) action();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowUp:
        node.previousFocus();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.arrowDown:
        node.nextFocus();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Reduced motion: the ring appears instantly instead of animating, and
    // hover fades drop to an instant switch (UIX-5 motion).
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    Widget child = widget.child;
    if (widget.builder != null) {
      child = widget.builder!(context, _hovered, child);
    } else {
      final opacity = _pressed
          ? widget.pressedOpacity
          : _hovered
          ? widget.hoverOpacity
          : 1.0;
      child = reduceMotion
          ? Opacity(opacity: opacity, child: child)
          : AnimatedOpacity(
              opacity: opacity,
              duration: const Duration(milliseconds: 90),
              child: child,
            );
    }
    // Tactile press: a 0.97 scale confirms the press immediately and settles
    // back with the same quick curve (motion: tactile feedback is brief).
    final Widget press = reduceMotion
        ? child
        : AnimatedScale(
            scale: _pressed ? 0.97 : 1.0,
            duration: CcMotion.press,
            curve: CcMotion.easeOut,
            child: child,
          );
    final Widget body = MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        child: press,
      ),
    );
    // The ring sits outside the widget's own paint bounds so a border on the
    // widget (cards, tiles) never collides with it. Rounded corners follow the
    // focus target's own radius when it is a plain tappable (buttons, icons).
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: _focused
          ? Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                border: Border.all(color: CcColors.accent, width: 2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: body,
            )
          : body,
    );
  }
}
