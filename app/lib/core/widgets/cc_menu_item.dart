part of 'primitives.dart';

/// One row of a [CcMenu].
class CcMenuItem {
  const CcMenuItem(
    this.label, {
    this.onTap,
    this.icon,
    this.shortcut,
    this.danger = false,
    this.checked,
    this.separatorBefore = false,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final String? shortcut;
  final bool danger;

  /// Non-null renders a check column (toggle items).
  final bool? checked;
  final bool separatorBefore;
}
