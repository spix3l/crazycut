part of 'primitives.dart';

/// Text button with optional leading icon — `New Project`, `Export`,
/// `Cancel`, `Create project`, `Add to queue`.
class CcButton extends StatelessWidget {
  const CcButton({
    super.key,
    required this.label,
    this.icon,
    this.kind = CcButtonKind.primary,
    this.onPressed,
    this.height = 34,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.radius = CcRadius.md,
  });

  final String label;
  final IconData? icon;
  final CcButtonKind kind;
  final VoidCallback? onPressed;
  final double height;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final isPrimary = kind == CcButtonKind.primary;
    final disabled = onPressed == null;
    final fg = disabled
        ? CcColors.textTertiary
        : isPrimary
        ? CcColors.onAccent
        : CcColors.textSecondary;
    return CcTappable(
      onTap: onPressed,
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: Container(
        height: height,
        padding: padding,
        decoration: BoxDecoration(
          color: switch (kind) {
            CcButtonKind.primary => disabled ? CcColors.elevated2 : CcColors.accent,
            CcButtonKind.secondary => disabled ? CcColors.panel : CcColors.elevated,
            CcButtonKind.ghost => null,
          },
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[CcIcon(icon!, size: 14, color: fg), const SizedBox(width: 6)],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.style(size: 13, weight: CcType.semibold, color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
