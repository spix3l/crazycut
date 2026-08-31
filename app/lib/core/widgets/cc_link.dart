part of 'primitives.dart';

/// Inline accent link used inside fields (`Change`, `Browse`).
class CcLink extends StatelessWidget {
  const CcLink(this.label, {super.key, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Text(
        label,
        style: CcType.style(size: 12, weight: CcType.medium, color: CcColors.accent),
      ),
    );
  }
}
