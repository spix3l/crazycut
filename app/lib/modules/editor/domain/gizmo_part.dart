part of 'canvas_geometry.dart';

/// Which part of the gizmo a pointer grabbed. Handle indices index
/// [gizmoAnchors], so the handle opposite `i` is always `8 - i`.
enum GizmoPart { none, move, resize, rotate }
