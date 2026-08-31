part of 'security_scoped_bookmarks.dart';

/// What resolving a bookmark found: the file's current path (bookmarks
/// follow a moved/renamed file, unlike a stored path) and, when the bookmark
/// had gone stale, a fresh one to persist in its place.
class ResolvedBookmark {
  const ResolvedBookmark({required this.path, this.refreshedBookmark});

  final String path;
  final String? refreshedBookmark;
}
