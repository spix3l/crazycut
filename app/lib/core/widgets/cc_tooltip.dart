part of 'primitives.dart';

/// Hover tooltip. Material's `Tooltip` is off-limits here, and the timeline
/// leans on tooltips for the trim/shortcut hints, so this is the smallest
/// overlay-based stand-in that behaves.
class CcTooltip extends StatefulWidget {
  const CcTooltip({
    super.key,
    required this.message,
    required this.child,
    this.delay = const Duration(milliseconds: 450),
  });

  final String message;
  final Widget child;
  final Duration delay;

  @override
  State<CcTooltip> createState() => _CcTooltipState();
}

class _CcTooltipState extends State<CcTooltip> {
  OverlayEntry? _entry;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _remove();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(widget.delay, _show);
  }

  void _show() {
    if (_entry != null || !mounted || widget.message.isEmpty) return;
    final target = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (target == null || overlayBox == null || !target.attached) return;

    const screenMargin = 8.0;
    const gap = 6.0;
    const horizontalPadding = 16.0;
    const verticalPadding = 10.0;
    final maxBubbleWidth = overlayBox.size.width < 276
        ? overlayBox.size.width - screenMargin * 2
        : 260.0;
    final textPainter = TextPainter(
      text: TextSpan(text: widget.message, style: CcType.nano),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxBubbleWidth - horizontalPadding);
    final bubbleWidth = textPainter.width + horizontalPadding;
    final bubbleHeight = textPainter.height + verticalPadding;
    final targetOrigin = target.localToGlobal(Offset.zero, ancestor: overlayBox);
    final targetRect = targetOrigin & target.size;
    final left = (targetRect.center.dx - bubbleWidth / 2).clamp(
      screenMargin,
      overlayBox.size.width - bubbleWidth - screenMargin,
    );
    final above = targetRect.top - bubbleHeight - gap;
    final top = (above >= screenMargin ? above : targetRect.bottom + gap).clamp(
      screenMargin,
      overlayBox.size.height - bubbleHeight - screenMargin,
    );

    _entry = OverlayEntry(
      builder: (context) => Positioned(
        left: left,
        top: top,
        width: bubbleWidth,
        child: IgnorePointer(
          child: CcReveal(
            duration: CcMotion.quick,
            offset: const Offset(0, 2),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: CcColors.elevated2,
                borderRadius: CcRadius.brSm,
                border: CcBorders.allStrong,
              ),
              child: Text(widget.message, style: CcType.nano),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  void _remove() {
    _timer?.cancel();
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (focused) => focused ? _schedule() : _remove(),
      child: MouseRegion(
        onEnter: (_) => _schedule(),
        onExit: (_) => _remove(),
        child: widget.child,
      ),
    );
  }
}
