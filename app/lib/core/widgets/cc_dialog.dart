import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../design/tokens.dart';
import 'primitives.dart';

/// Modal shell shared by "New project" and "Export": scrim, elevated panel,
/// bordered header with a close affordance, scrollable body and a footer.
class CcDialogShell extends StatelessWidget {
  const CcDialogShell({
    super.key,
    required this.title,
    required this.width,
    required this.sections,
    required this.actions,
    this.onClose,
    this.bodyPadding = const EdgeInsets.all(24),
    this.gap = 20,
  });

  final String title;
  final double width;
  final List<Widget> sections;
  final List<Widget> actions;
  final VoidCallback? onClose;
  final EdgeInsets bodyPadding;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: CcColors.panel,
        borderRadius: CcRadius.brLg,
        border: CcBorders.allStrong,
        boxShadow: CcDeco.dialogShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 59,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: const BoxDecoration(border: CcBorders.bottom),
            child: Row(
              children: [
                Expanded(child: Text(title, style: CcType.dialogTitle)),
                const SizedBox(width: 12),
                CcTappable(onTap: onClose, child: const CcIcon(LucideIcons.x, size: 18)),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: bodyPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < sections.length; i++) ...[
                    if (i > 0) SizedBox(height: gap),
                    sections[i],
                  ],
                ],
              ),
            ),
          ),
          Container(
            height: 66,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: const BoxDecoration(border: CcBorders.top),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  actions[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-bleed scrim that centres a dialog over the screen underneath it.
class CcModalBarrier extends StatelessWidget {
  const CcModalBarrier({
    super.key,
    required this.child,
    this.onDismiss,
    this.color = CcColors.scrim,
    this.alignment = Alignment.center,
    this.padding = const EdgeInsets.symmetric(vertical: 48),
  });

  final Widget child;
  final VoidCallback? onDismiss;
  final Color color;
  final Alignment alignment;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: ColoredBox(color: color),
          ),
        ),
        Positioned.fill(
          child: Padding(
            padding: padding,
            child: Align(alignment: alignment, child: child),
          ),
        ),
      ],
    );
  }
}

/// Label above a field, with the field below it.
class CcField extends StatelessWidget {
  const CcField({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: CcType.label),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

/// Small modal text prompt (rename track, rename marker, rename project).
/// Returns null when dismissed.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  String initialValue = '',
  String label = 'Name',
  String confirmLabel = 'Rename',
}) {
  final completer = Completer<String?>();
  final controller = TextEditingController(text: initialValue);
  final overlay = Overlay.of(context);
  late OverlayEntry entry;

  void finish(String? value) {
    if (completer.isCompleted) return;
    entry.remove();
    controller.dispose();
    completer.complete(value);
  }

  entry = OverlayEntry(
    builder: (context) => CcModalBarrier(
      onDismiss: () => finish(null),
      child: CcDialogShell(
        title: title,
        width: 420,
        onClose: () => finish(null),
        sections: [
          CcField(
            label: label,
            child: CcTextField(
              controller: controller,
              autofocus: true,
              onSubmitted: (value) => finish(value.trim()),
            ),
          ),
        ],
        actions: [
          CcButton(
            label: 'Cancel',
            kind: CcButtonKind.secondary,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            onPressed: () => finish(null),
          ),
          CcButton(
            label: confirmLabel,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            onPressed: () => finish(controller.text.trim()),
          ),
        ],
      ),
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

/// Yes/no confirmation with a destructive-styled confirm button.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
}) {
  final completer = Completer<bool>();
  final overlay = Overlay.of(context);
  late OverlayEntry entry;

  void finish(bool value) {
    if (completer.isCompleted) return;
    entry.remove();
    completer.complete(value);
  }

  entry = OverlayEntry(
    builder: (context) => CcModalBarrier(
      onDismiss: () => finish(false),
      child: CcDialogShell(
        title: title,
        width: 440,
        onClose: () => finish(false),
        sections: [
          Text(
            message,
            style: CcType.style(size: 13, color: CcColors.textSecondary, height: 1.5),
          ),
        ],
        actions: [
          CcButton(
            label: 'Cancel',
            kind: CcButtonKind.secondary,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            onPressed: () => finish(false),
          ),
          CcButton(
            label: confirmLabel,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            onPressed: () => finish(true),
          ),
        ],
      ),
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

/// One-action message dialog for errors and other blocking information.
Future<void> showMessageDialog(
  BuildContext context, {
  required String title,
  required String message,
  String closeLabel = 'Close',
}) {
  final completer = Completer<void>();
  final overlay = Overlay.of(context);
  late OverlayEntry entry;

  void finish() {
    if (completer.isCompleted) return;
    entry.remove();
    completer.complete();
  }

  entry = OverlayEntry(
    builder: (context) => CcModalBarrier(
      onDismiss: finish,
      child: CcDialogShell(
        title: title,
        width: 440,
        onClose: finish,
        sections: [
          Text(
            message,
            style: CcType.style(size: 13, color: CcColors.textSecondary, height: 1.5),
          ),
        ],
        actions: [CcButton(label: closeLabel, onPressed: finish)],
      ),
    ),
  );
  overlay.insert(entry);
  return completer.future;
}
