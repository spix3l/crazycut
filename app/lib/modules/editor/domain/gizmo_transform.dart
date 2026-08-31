part of 'canvas_geometry.dart';

/// The transform values a drag resolves to. Nulls are "leave this alone".
typedef GizmoTransform = ({double? x, double? y, double? scale, double? rotation});

/// Unit vector from a rect's centre towards anchor [index], in the rect's own
/// unrotated frame.
Offset gizmoAnchorDirection(int index) => Offset(
  switch (index % 3) { 0 => -1.0, 2 => 1.0, _ => 0.0 },
  switch (index ~/ 3) { 0 => -1.0, 2 => 1.0, _ => 0.0 },
);
