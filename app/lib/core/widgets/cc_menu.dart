part of 'primitives.dart';

/// Floating verb list used by context menus and the track menu. Disabled rows
/// stay visible so the menu shape does not jump between targets.
class CcMenu extends StatelessWidget {
  const CcMenu({
    super.key,
    required this.items,
    this.onSelected,
    this.width = 210,
    this.maxHeight,
  });

  final List<CcMenuItem> items;
  final VoidCallback? onSelected;
  final double width;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      constraints: maxHeight == null ? null : BoxConstraints(maxHeight: maxHeight!),
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brMd,
        border: CcBorders.allStrong,
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 20, offset: Offset(0, 8)),
        ],
      ),
      child: SingleChildScrollView(
        primary: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _rows(),
        ),
      ),
    );
  }

  /// The rows, with separators. The first enabled row autofocuses when the
  /// menu opens so keyboard users start navigation there (UIX-3).
  List<Widget> _rows() {
    final firstEnabledIndex = items.indexWhere((item) => item.onTap != null);
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.separatorBefore) {
        rows.add(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: SizedBox(height: 1, child: ColoredBox(color: CcColors.border)),
          ),
        );
      }
      rows.add(
        CcTappable(
          autofocus: i == firstEnabledIndex,
          onTap: item.onTap == null
              ? null
              : () {
                  onSelected?.call();
                  item.onTap!();
                },
          builder: (context, hovered, _) => Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            color: hovered && item.onTap != null
                ? CcColors.elevated2
                : const Color(0x00000000),
            child: Row(
              children: [
                if (item.checked != null) ...[
                  CcIcon(
                    item.checked! ? LucideIcons.check : LucideIcons.minus,
                    size: 12,
                    color: item.checked! ? CcColors.accent : CcColors.textTertiary,
                  ),
                  const SizedBox(width: 8),
                ] else if (item.icon != null) ...[
                  CcIcon(item.icon!, size: 12, color: CcColors.textSecondary),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CcType.style(
                      size: 12,
                      color: item.onTap == null
                          ? CcColors.textTertiary
                          : item.danger
                          ? CcColors.error
                          : CcColors.textPrimary,
                    ),
                  ),
                ),
                if (item.shortcut != null) Text(item.shortcut!, style: CcType.nano),
              ],
            ),
          ),
          child: const SizedBox.shrink(),
        ),
      );
    }
    return rows;
  }
}

/// Opens a [CcMenu] anchored to the bottom edge of [anchorContext].
///
/// This is the app's only menu entry point: buttons and right-click targets
/// alike pass the widget that owns the gesture, so the menu opens beside it
/// instead of being told where the pointer was.
void showCcMenu(BuildContext anchorContext, List<CcMenuItem> items) {
  final anchor = anchorContext.findRenderObject() as RenderBox?;
  if (anchor == null || !anchor.attached) return;
  final position = anchor.localToGlobal(Offset(0, anchor.size.height + 4));
  final overlay = Overlay.of(anchorContext);
  final overlayBox = overlay.context.findRenderObject() as RenderBox?;
  if (overlayBox == null) return;
  // Remember who opened the menu so focus can return after it closes (UIX-3).
  final previousFocus = FocusManager.instance.primaryFocus;
  late OverlayEntry entry;
  void close() {
    entry.remove();
    // Only restore focus if the user has not already moved it somewhere else
    // (e.g. clicked another control while the menu was open).
    final current = FocusManager.instance.primaryFocus;
    if (previousFocus != null && (current == null || current.context == null)) {
      previousFocus.requestFocus();
    }
  }
  const edgeMargin = 20.0;
  const preferredMenuWidth = 210.0;
  final separatorHeight = items.where((item) => item.separatorBefore).length * 9.0;
  // Ten pixels of explicit vertical padding plus the one-pixel border on each
  // edge. Keeping this equal to CcMenu's real height prevents bottom clipping.
  final estimatedHeight = items.length * 28.0 + separatorHeight + 12;
  final requested = overlayBox.globalToLocal(position);
  final horizontalMargin = overlayBox.size.width < edgeMargin * 2
      ? overlayBox.size.width / 2
      : edgeMargin;
  final verticalMargin = overlayBox.size.height < edgeMargin * 2
      ? overlayBox.size.height / 2
      : edgeMargin;
  final availableWidth = (overlayBox.size.width - horizontalMargin * 2).clamp(
    0.0,
    double.infinity,
  );
  final availableHeight = (overlayBox.size.height - verticalMargin * 2).clamp(
    0.0,
    double.infinity,
  );
  final menuWidth = preferredMenuWidth.clamp(0.0, availableWidth);
  final menuHeight = estimatedHeight.clamp(0.0, availableHeight);
  final dx = requested.dx.clamp(
    horizontalMargin,
    overlayBox.size.width - menuWidth - horizontalMargin,
  );
  final dy = requested.dy.clamp(
    verticalMargin,
    overlayBox.size.height - menuHeight - verticalMargin,
  );
  entry = OverlayEntry(
    builder: (context) => Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: close),
        ),
        Positioned(
          left: dx,
          top: dy,
          // Menus fade in at their anchor: the position already ties them to
          // the trigger, so any translate would risk edge clipping.
          child: CcReveal(
            duration: CcMotion.menu,
            offset: Offset.zero,
            child: CcMenu(
              items: items,
              onSelected: close,
              width: menuWidth,
              maxHeight: availableHeight,
            ),
          ),
        ),
      ],
    ),
  );
  overlay.insert(entry);
}
