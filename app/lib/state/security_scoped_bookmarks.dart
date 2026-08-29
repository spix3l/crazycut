import 'dart:io';

import 'package:flutter/services.dart';

/// macOS App Sandbox only grants access to a file the user picked for the
/// run it was picked in (`com.apple.security.files.user-selected.read-write`
/// in `Release.entitlements`). A security-scoped bookmark is the sandbox's
/// mechanism for re-granting that access on a later launch without asking
/// the user to pick the file again; without one, a project relaunch reports
/// every externally-picked file as offline even though nothing moved.
///
/// No-op on every platform but macOS, where `AppDelegate.swift`'s
/// `dev.crazycut/system` channel implements the bookmark calls.
class SecurityScopedBookmarks {
  SecurityScopedBookmarks._();

  static const _channel = MethodChannel('dev.crazycut/system');

  static bool get _supported => Platform.isMacOS;

  /// Captures a bookmark for [path] right after the user picked it (import,
  /// open project, save-as). Returns null off macOS or if the OS refuses —
  /// callers just keep working without one, same as before this existed.
  static Future<String?> create(String path) async {
    if (!_supported) return null;
    try {
      return await _channel.invokeMethod<String>('bookmarkCreate', {
        'path': path,
      });
    } on Object {
      return null;
    }
  }

  /// Resolves [bookmark] and starts (and holds, for the rest of this
  /// process) access to the file it points at.
  static Future<ResolvedBookmark?> resolve(String bookmark) async {
    if (!_supported) return null;
    try {
      final result = await _channel.invokeMethod<Map>('bookmarkResolve', {
        'bookmark': bookmark,
      });
      final path = result?['path'] as String?;
      if (path == null) return null;
      return ResolvedBookmark(
        path: path,
        refreshedBookmark: result?['bookmark'] as String?,
      );
    } on Object {
      return null;
    }
  }
}

/// What resolving a bookmark found: the file's current path (bookmarks
/// follow a moved/renamed file, unlike a stored path) and, when the bookmark
/// had gone stale, a fresh one to persist in its place.
class ResolvedBookmark {
  const ResolvedBookmark({required this.path, this.refreshedBookmark});

  final String path;
  final String? refreshedBookmark;
}
