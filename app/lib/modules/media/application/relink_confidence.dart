part of 'media_relink.dart';

/// How confident a relink match is (IMP-16).
enum RelinkConfidence {
  /// Content hash matched: this is the same file, wherever it moved to.
  exact,

  /// Name and size matched: almost certainly right, but confirm it.
  proposed,
}
