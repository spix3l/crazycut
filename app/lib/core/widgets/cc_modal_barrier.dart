part of 'cc_dialog.dart';

/// Full-bleed scrim that centres a dialog over the screen underneath it.
class CcModalBarrier extends StatelessWidget {
  const CcModalBarrier({
    super.key,
    required this.child,
    this.onDismiss,
    this.color = CcColors.scrim,
    this.alignment = Alignment.center,
    this.padding = const EdgeInsets.symmetric(vertical: 48),
  });

  final Widget child;
  final VoidCallback? onDismiss;
  final Color color;
  final Alignment alignment;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    // Dialog arrival: the scrim fades, the panel scales up from 0.97 with a
    // slight rise. Reduced motion drops the panel movement.
    final reduce = CcMotion.reduceMotionOf(context);
    final entrance = CcMotion.surface;
    final scrimBody = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDismiss,
      child: ColoredBox(color: color),
    );
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
          onDismiss?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          // The Positioned stays a direct Stack child; the fade wraps the
          // scrim body, not the Positioned, so parent data is preserved.
          Positioned.fill(
            child: reduce
                ? scrimBody
                : TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: entrance,
                    curve: CcMotion.easeOut,
                    builder: (context, t, child) => Opacity(opacity: t, child: child),
                    child: scrimBody,
                  ),
          ),
          Positioned.fill(
            child: Padding(
              padding: padding,
              child: Align(
                alignment: alignment,
                child: CcReveal(
                  duration: entrance,
                  offset: const Offset(0, 6),
                  child: child,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
