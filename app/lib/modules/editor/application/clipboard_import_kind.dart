part of 'editor_controller.dart';

/// What a paste found on the system clipboard (IMP-1).
enum ClipboardImportKind {
  /// Nothing importable — the caller may fall through to its own paste.
  nothing,
  files,
  image,
  url,

  /// Something was there, but nothing the editor accepts.
  unsupported,
}
