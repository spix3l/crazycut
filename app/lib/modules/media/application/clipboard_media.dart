import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

part 'system_clipboard_media_reader.dart';

/// What the system clipboard is offering the editor right now (IMP-1).
///
/// Only one of [paths] and [image] is ever populated: when a copy carries both
/// a file promise and a bitmap — which most browsers and screenshot tools do —
/// the host prefers the file, because the file is a real source the project can
/// keep pointing at.
@immutable
class ClipboardMedia {
  const ClipboardMedia({
    this.paths = const [],
    this.image,
    this.imageExtension = 'png',
    this.text,
    this.sequence,
  });

  static const ClipboardMedia empty = ClipboardMedia();

  /// Files copied in a file manager, in the order the OS reports them.
  final List<String> paths;

  /// A raw bitmap (a screenshot, an image copied out of a browser), already
  /// encoded as [imageExtension] by the host.
  final Uint8List? image;
  final String imageExtension;

  /// Plain text, which may be a URL or a path typed somewhere else.
  final String? text;

  /// The host's clipboard generation counter, when it has one. It lets a paste
  /// tell "the user copied something new" from "the clipboard still holds what
  /// it held when they copied clips inside the app".
  final int? sequence;

  bool get hasMedia => paths.isNotEmpty || image != null;

  bool get isEmpty => !hasMedia && (text == null || text!.trim().isEmpty);
}

/// Reads media off the system clipboard. Abstracted so tests can paste without
/// a window, a pasteboard, or a platform channel.
abstract interface class ClipboardMediaReader {
  Future<ClipboardMedia> read();

  /// The clipboard generation counter alone, or null where the host has none.
  Future<int?> sequence();
}
