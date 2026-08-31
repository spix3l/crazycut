part of 'primitives.dart';

/// Icon wrapper so every call site is explicit about size and colour
/// (there is no `IconTheme` from a `MaterialApp` in this app).
class CcIcon extends StatelessWidget {
  const CcIcon(this.icon, {super.key, this.size = 14, this.color = CcColors.textSecondary});

  final IconData icon;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Icon(icon, size: size, color: color);
  }
}
