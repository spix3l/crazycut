import 'package:flutter/widgets.dart';

import '../design/tokens.dart';
import 'primitives.dart';

/// Empty state: a compact icon chip inline with the title, then teaching copy
/// and actions below. The icon is a small inline mark, not a centered badge
/// stamped above every empty space.
class CcEmptyState extends StatelessWidget {
  const CcEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.footnote,
    this.action,
    this.badgeSize = 48,
    this.badgeRadius = 14,
    this.iconSize = 22,
    this.bordered = true,
  });

  final IconData icon;
  final String title;
  final String? description;
  final String? footnote;
  final Widget? action;
  final double badgeSize;
  final double badgeRadius;
  final double iconSize;
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: CcColors.elevated,
          borderRadius: BorderRadius.circular(9),
          border: bordered ? CcBorders.allStrong : null,
        ),
        child: CcIcon(icon, size: 16, color: CcColors.textSecondary),
      ),
      const SizedBox(width: 12),
      Expanded(child: Text(title, style: CcType.style(size: 13, weight: CcType.semibold))),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: actions),
        if (description != null) ...[
          const SizedBox(height: 10),
          Text(description!, style: CcType.tiny),
        ],
        if (action != null) ...[const SizedBox(height: 12), Align(alignment: Alignment.centerLeft, child: action!)],
        if (footnote != null) ...[
          const SizedBox(height: 8),
          Text(footnote!, style: CcType.micro),
        ],
      ],
    );
  }
}
