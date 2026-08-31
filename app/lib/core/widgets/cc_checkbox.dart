part of 'primitives.dart';

/// Checkbox in the export options row / effect stack header.
class CcCheckbox extends StatelessWidget {
  const CcCheckbox({super.key, required this.checked, this.size = 15, this.onTap});

  final bool checked;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: checked ? CcColors.accent : CcColors.elevated,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: checked ? CcColors.accent : CcColors.borderStrong),
        ),
        child: checked
            ? CcIcon(LucideIcons.check, size: size - 4, color: CcColors.onAccent)
            : null,
      ),
    );
  }
}
