import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';

/// A little non-modal toast, bottom center, auto-dismissed.
///
/// Used for fire-and-forget confirmations (export finished, silence removal)
/// where a dialog would interrupt the flow. At most one toast per call; the
/// caller owns when to show it.
void showCcToast(
  BuildContext context, {
  required String message,
  IconData icon = LucideIcons.circleCheck,
  Color color = CcColors.success,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 4),
  OverlayState? overlay,
}) {
  final host = overlay ?? Overlay.of(context);
  late OverlayEntry entry;
  Timer? timer;

  void dismiss() {
    timer?.cancel();
    if (entry.mounted) entry.remove();
  }

  timer = Timer(duration, dismiss);
  entry = OverlayEntry(
    builder:
        (context) => Positioned(
          left: 0,
          right: 0,
          bottom: 88,
          child: IgnorePointer(
            ignoring: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: _ToastPill(
                    message: message,
                    icon: icon,
                    color: color,
                    actionLabel: actionLabel,
                    onAction: () {
                      final action = onAction;
                      dismiss();
                      action?.call();
                    },
                    onClose: dismiss,
                  ),
                ),
              ],
            ),
          ),
        ),
  );
  host.insert(entry);
}

class _ToastPill extends StatelessWidget {
  const _ToastPill({
    required this.message,
    required this.icon,
    required this.color,
    required this.onClose,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData icon;
  final Color color;
  final VoidCallback onClose;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 480),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: CcColors.elevated2,
        borderRadius: CcRadius.brMd,
        border: Border.all(color: CcColors.borderStrong),
        boxShadow: CcDeco.dialogShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CcIcon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              style: CcType.style(size: 12, color: CcColors.textPrimary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(width: 10),
            CcTappable(
              onTap: onAction,
              child: Text(
                actionLabel!,
                style: CcType.style(
                  size: 12,
                  weight: CcType.semibold,
                  color: CcColors.accent,
                ),
              ),
            ),
          ],
          const SizedBox(width: 6),
          CcTappable(
            onTap: onClose,
            child: const CcIcon(
              LucideIcons.x,
              size: 13,
              color: CcColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}
