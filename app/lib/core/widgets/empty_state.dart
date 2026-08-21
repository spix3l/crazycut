import 'package:flutter/widgets.dart';

import '../design/tokens.dart';
import 'primitives.dart';

/// Centred icon-badge + title + description block, used by every empty state
/// in the app (media pool, export queue, monitor).
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
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: badgeSize,
          height: badgeSize,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: CcColors.elevated,
            borderRadius: BorderRadius.circular(badgeRadius),
            border: bordered ? CcBorders.allStrong : null,
          ),
          child: CcIcon(icon, size: iconSize, color: CcColors.textSecondary),
        ),
        const SizedBox(height: 16),
        Text(title, style: CcType.style(size: 13, weight: CcType.semibold)),
        if (description != null) ...[
          const SizedBox(height: 8),
          Text(description!, textAlign: TextAlign.center, style: CcType.tiny),
        ],
        if (action != null) ...[const SizedBox(height: 8), action!],
        if (footnote != null) ...[
          const SizedBox(height: 8),
          Text(footnote!, textAlign: TextAlign.center, style: CcType.micro),
        ],
      ],
    );
  }
}
