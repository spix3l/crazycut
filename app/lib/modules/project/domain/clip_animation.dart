/// Read side of the generated clip-animation spec (`extra['clipAnim']`).
///
/// The spec is authored by `TimelineEdits`, but three places have to agree on
/// what it says: the editor (preview rasters), the exporter (baked textures)
/// and the native worker (frame selection). These helpers are the one place
/// that reads it, so a typewriter reveals at the same rate in all three.
library;

const String kClipAnimKey = 'clipAnim';
const String kLegacyClipAnimKey = 'imageAnim';

/// Default length of an entry or leave animation, in seconds.
const double kClipEdgeDefaultSeconds = 0.4;

/// Reveal rate used by projects saved before the typewriter took its duration
/// from the entry animation. Kept so those clips still type at their old pace.
const double kLegacyTypewriterCharsPerSecond = 24.0;

/// Neither edge may eat more than half the clip, or a short clip would still
/// be arriving while it is already leaving. Clips shorter than 0.1 s cannot
/// hold the 0.05 s minimum on both sides, so they keep half the clip instead
/// of throwing on an inverted clamp range.
double clampEdgeSeconds(double seconds, double clipSeconds) {
  if (clipSeconds <= 0) return 0.05;
  final max = clipSeconds / 2;
  if (max <= 0) return 0;
  if (max < 0.05) return seconds.clamp(0.0, max);
  return seconds.clamp(0.05, max);
}

/// The spec on a clip's extra payload, or null when it has no generated
/// animation. Accepts the pre-v1 `imageAnim` key and the `in`/`out` edge names.
Map<String, dynamic>? clipAnimSpecOf(Map<String, dynamic>? extra) {
  final raw = extra?[kClipAnimKey] ?? extra?[kLegacyClipAnimKey];
  return raw is Map ? Map<String, dynamic>.from(raw) : null;
}

String canonicalEdge(String side) => switch (side) {
  'in' => 'entry',
  'out' => 'leave',
  _ => side,
};

/// Preset id on one edge ('entry' or 'leave') of [spec], or null when unset.
String? clipAnimEdgeType(Map<String, dynamic>? spec, String side) {
  if (spec == null) return null;
  final edge = spec[canonicalEdge(side)] ?? spec[side];
  return edge is Map ? edge['type'] as String? : null;
}

double clipAnimEdgeSeconds(Map<String, dynamic>? spec, String side) {
  final edge = spec?[canonicalEdge(side)] ?? spec?[side];
  return edge is Map
      ? ((edge['seconds'] as num?)?.toDouble() ?? kClipEdgeDefaultSeconds)
      : kClipEdgeDefaultSeconds;
}

/// How long a typewriter entry takes to reveal the whole string, or null when
/// the clip does not type in. [clipSeconds] bounds it the same way the
/// generated keyframes are bounded, so preview and export reveal in step.
double? typewriterRevealSeconds(
  Map<String, dynamic>? spec, {
  required double clipSeconds,
}) {
  if (clipAnimEdgeType(spec, 'entry') != 'typewriter') return null;
  return clampEdgeSeconds(clipAnimEdgeSeconds(spec, 'entry'), clipSeconds);
}

/// Characters per second that reveals [runeCount] runes in [revealSeconds].
/// An empty string or a zero-length reveal types instantly rather than
/// dividing by zero.
double typewriterCharsPerSecond(int runeCount, double revealSeconds) {
  if (runeCount <= 0 || revealSeconds <= 0) return double.infinity;
  return runeCount / revealSeconds;
}
