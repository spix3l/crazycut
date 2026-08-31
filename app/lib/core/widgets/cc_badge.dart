part of 'primitives.dart';

/// Rounded dark pill used for badges over thumbnails.
class CcBadge extends StatelessWidget {
  const CcBadge(
    this.label, {
    super.key,
    this.fontSize = 11,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    this.radius = CcRadius.sm,
  });

  final String label;
  final double fontSize;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: CcColors.badgeBg,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        label,
        style: CcType.style(size: fontSize, weight: CcType.medium),
      ),
    );
  }
}
