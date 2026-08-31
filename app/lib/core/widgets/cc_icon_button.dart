part of 'primitives.dart';

/// Square icon-only button, optionally toggled on (accent outline).
class CcIconButton extends StatelessWidget {
  const CcIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.size = 31,
    this.iconSize = 15,
    this.active = false,
    this.enabled = true,
    this.outlined = false,
    this.radius = CcRadius.sm,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final bool active;
  final bool enabled;
  final bool outlined;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: enabled ? onPressed : null,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? CcColors.elevated2 : (outlined ? CcColors.elevated : null),
          borderRadius: BorderRadius.circular(radius),
          border: active && outlined ? Border.all(color: CcColors.accent) : null,
        ),
        child: CcIcon(
          icon,
          size: iconSize,
          color: !enabled
              ? CcColors.textTertiary
              : active
              ? (outlined ? CcColors.accent : CcColors.textPrimary)
              : CcColors.textSecondary,
        ),
      ),
    );
  }
}
