part of 'primitives.dart';

/// Compact dropdown pill (`Last opened`, `Auto`, `Fit`, `Full`).
class CcDropdown extends StatelessWidget {
  const CcDropdown({
    super.key,
    required this.value,
    this.onTap,
    this.height = 32,
    this.width,
    this.fontSize = 13,
    this.bordered = false,
    this.radius = CcRadius.sm,
  });

  final String value;
  final VoidCallback? onTap;
  final double height;
  final double? width;
  final double fontSize;
  final bool bordered;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Container(
        height: height,
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: CcColors.elevated,
          borderRadius: BorderRadius.circular(radius),
          border: bordered ? Border.all(color: CcColors.borderStrong) : null,
        ),
        child: Row(
          mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max,
          children: [
            Expanded(
              flex: width == null ? 0 : 1,
              child: Text(
                value,
                style: CcType.style(
                  size: fontSize,
                  color: bordered ? CcColors.textPrimary : CcColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            CcIcon(
              LucideIcons.chevronDown,
              size: fontSize,
              color: bordered ? CcColors.textTertiary : CcColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
