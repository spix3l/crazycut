part of 'cc_dialog.dart';

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
  OverlayState? overlay,
}) {
  final completer = Completer<String?>();
  final controller = TextEditingController(text: initialValue);
  // Callers above the navigator (platform menu items) hand the overlay in:
  // `Overlay.of` can't resolve through the navigator's context, whose own
  // Overlay lives *below* it.
  final host = overlay ?? Overlay.of(context);
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
  host.insert(entry);
  return completer.future;
}

/// Yes/no confirmation with a destructive-styled confirm button.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  OverlayState? overlay,
}) {
  final completer = Completer<bool>();
  final host = overlay ?? Overlay.of(context);
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
  host.insert(entry);
  return completer.future;
}

/// One-action message dialog for errors and other blocking information.
Future<void> showMessageDialog(
  BuildContext context, {
  required String title,
  required String message,
  String closeLabel = 'Close',
  OverlayState? overlay,
}) {
  final completer = Completer<void>();
  final host = overlay ?? Overlay.of(context);
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
  host.insert(entry);
  return completer.future;
}
