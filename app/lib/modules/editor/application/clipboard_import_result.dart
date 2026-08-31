part of 'editor_controller.dart';

class ClipboardImportResult {
  const ClipboardImportResult(this.kind, {this.count = 0, this.error});

  final ClipboardImportKind kind;

  /// How many assets the paste brought in.
  final int count;

  /// Why an otherwise valid paste failed, ready to show to the user.
  final String? error;

  bool get handled => kind != ClipboardImportKind.nothing;
}
