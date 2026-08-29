import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

/// The real clipboard, read through the host app over `dev.crazycut/system`.
///
/// Flutter's own [Clipboard] only speaks plain text, so files and bitmaps come
/// from the platform side. Where that channel is missing (tests, a headless
/// tool, a platform without a runner) this degrades to text, which still covers
/// pasting a media URL.
class SystemClipboardMediaReader implements ClipboardMediaReader {
  const SystemClipboardMediaReader();

  static const MethodChannel _channel = MethodChannel('dev.crazycut/system');

  @override
  Future<ClipboardMedia> read() async {
    try {
      final payload = await _channel.invokeMapMethod<String, Object?>(
        'readClipboardMedia',
      );
      if (payload != null) return _decode(payload);
    } on MissingPluginException {
      // No host channel here: fall through to the text-only clipboard.
    } catch (e) {
      debugPrint('clipboard read failed: $e');
    }
    return ClipboardMedia(text: await _plainText());
  }

  @override
  Future<int?> sequence() async {
    try {
      return await _channel.invokeMethod<int>('clipboardSequence');
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('clipboard sequence failed: $e');
      return null;
    }
  }

  static ClipboardMedia _decode(Map<String, Object?> payload) {
    final paths =
        (payload['paths'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    final image = payload['image'];
    final text = payload['text'] as String?;
    return ClipboardMedia(
      paths: paths,
      image: image is Uint8List ? image : null,
      imageExtension: (payload['imageExtension'] as String?) ?? 'png',
      text: text != null && text.isNotEmpty ? text : null,
      sequence: (payload['sequence'] as num?)?.toInt(),
    );
  }

  static Future<String?> _plainText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      return text != null && text.isNotEmpty ? text : null;
    } catch (_) {
      return null;
    }
  }
}

/// Writes a pasted bitmap to disk so it becomes an ordinary file source.
///
/// A pasted screenshot has no file behind it, and the project stores paths, not
/// pixels — so the bytes have to land somewhere durable before the asset can
/// exist. [directory] is the project's own media folder when it has one, which
/// is where a later "collect media" would have put the file anyway.
Future<File> writePastedImage(
  Uint8List bytes, {
  required Directory directory,
  String extension = 'png',
  String stem = 'Pasted image',
}) async {
  await directory.create(recursive: true);
  final base = '${directory.path}${Platform.pathSeparator}$stem';
  var target = '$base.$extension';
  for (var i = 1; File(target).existsSync() && i < 1000; i++) {
    target = '$base $i.$extension';
  }
  final file = File(target);
  await file.writeAsBytes(bytes, flush: true);
  return file;
}
