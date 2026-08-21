import 'package:crazycut_app/data/param_value.dart';

/// Clip-level built-in transform (FX-9).
///
/// JSON: `{"x","y","scale","rotation","anchor","opacity"}` are [ParamValue]s
/// (animatable); `flipH`/`flipV`/`framing` are plain values. x/y are
/// sequence-frame pixels relative to the frame center; scale in %, rotation
/// in degrees CW, opacity 0..100.
class ClipTransform {
  ClipTransform({
    ParamValue? x,
    ParamValue? y,
    ParamValue? scale,
    ParamValue? rotation,
    ParamValue? anchor,
    ParamValue? opacity,
    this.flipH = false,
    this.flipV = false,
    this.framing = 'fit',
  })  : x = x ?? ParamValue.staticNum(0),
        y = y ?? ParamValue.staticNum(0),
        scale = scale ?? ParamValue.staticNum(100),
        rotation = rotation ?? ParamValue.staticNum(0),
        anchor = anchor ?? ParamValue.point(0, 0),
        opacity = opacity ?? ParamValue.staticNum(100);

  factory ClipTransform.fromJson(Map<String, dynamic>? j) => ClipTransform(
        x: _pv(j?['x'], static: 0.0),
        y: _pv(j?['y'], static: 0.0),
        scale: _pv(j?['scale'], static: 100.0),
        rotation: _pv(j?['rotation'], static: 0.0),
        anchor: _pv(j?['anchor'], point: true),
        opacity: _pv(j?['opacity'], static: 100.0),
        flipH: (j?['flipH'] as bool?) ?? false,
        flipV: (j?['flipV'] as bool?) ?? false,
        framing: (j?['framing'] as String?) ?? 'fit',
      );

  /// Quarantine-not-throw: a malformed param payload falls back to defaults.
  static ParamValue _pv(dynamic raw, {double static = 0.0, bool point = false}) =>
      raw is Map<String, dynamic>
          ? ParamValue.from(raw)
          : (point ? ParamValue.point(0, 0) : ParamValue.staticNum(static));

  final ParamValue x;
  final ParamValue y;
  final ParamValue scale;
  final ParamValue rotation;
  final ParamValue anchor;
  final ParamValue opacity;
  bool flipH;
  bool flipV;
  String framing;

  ClipTransform copy() => ClipTransform.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'x': x.toJson(),
        'y': y.toJson(),
        'scale': scale.toJson(),
        'rotation': rotation.toJson(),
        'anchor': anchor.toJson(),
        'opacity': opacity.toJson(),
        'flipH': flipH,
        'flipV': flipV,
        'framing': framing,
      };
}
