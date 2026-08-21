import 'package:crazycut_app/models/rational.dart';

/// Animatable parameter value — mirrors engine `graph/keyframes.cpp`.
///
/// Stored JSON per `02-data-model.md` §5:
/// `{"static": <num|{x,y}>, "keyframes":[{"t":"n/d","v":<same shape>,"interp":"linear"}]}`.
/// Keyframe times are clip-local rational seconds; when [keyframes] is
/// non-empty it wins over [static].
class ParamValue {
  ParamValue({this.static, List<Map<String, dynamic>>? keyframes})
    : keyframes = keyframes ?? [];

  factory ParamValue.staticNum(double v) => ParamValue(static: v);

  factory ParamValue.point(double x, double y) =>
      ParamValue(static: {'x': x, 'y': y});

  /// Quarantine-not-throw: malformed payloads fall back to a zero static.
  factory ParamValue.from(dynamic json) => ParamValue(
    static:
        json is Map<String, dynamic>
            ? (json.containsKey('static') ? json['static'] : 0.0)
            : 0.0,
    keyframes: _parseKeyframes(
      json is Map<String, dynamic> ? json['keyframes'] : null,
    ),
  );

  dynamic static;
  final List<Map<String, dynamic>> keyframes;

  bool get animated => keyframes.isNotEmpty;

  static List<Map<String, dynamic>> _parseKeyframes(dynamic raw) =>
      (raw is List<dynamic>)
          ? raw
              .whereType<Map>()
              .map((k) => <String, dynamic>{...k.cast<String, dynamic>()})
              .toList()
          : [];

  /// The evaluated value at the current state: keyframe evaluation is
  /// time-driven, so without an explicit time this yields [static] as-is
  /// (a no-op) and never invents a keyframe sample.
  dynamic get value => animated ? null : static;

  double numOr(double fallback) {
    final value = this.value;
    if (value is num) return value.toDouble();
    if (value is Map && value['y'] is num) {
      return (value['y'] as num).toDouble();
    }
    if (value is Map && value['x'] is num) {
      return (value['x'] as num).toDouble();
    }
    return fallback;
  }

  void sortKeys() => keyframes.sort((a, b) => _time(a).compareTo(_time(b)));

  Rt _time(Map<String, dynamic> k) => k['t'] == null ? Rt.zero() : _rt(k['t']);

  /// Public read for ops layers that need a key's time without touching
  /// internals.
  static Rt timeOf(Map<String, dynamic> k) =>
      k['t'] == null ? Rt.zero() : _rt(k['t']);

  static Rt _rt(dynamic t) {
    if (t is String) return Rt.parse(t);
    if (t is num) return Rt.fromSeconds(t.toDouble());
    return Rt.zero();
  }

  /// Evaluates at clip-local time [t], bit-matching the engine:
  /// clamp outside the span, then ease each segment by its LEFT key's interp.
  dynamic evaluate(Rt t) {
    if (!animated) return static;
    final keys = [...keyframes]..sort((a, b) => _time(a).compareTo(_time(b)));
    final firstT = _time(keys.first);
    final lastT = _time(keys.last);
    if (t <= firstT) return keys.first['v'];
    if (t >= lastT) return keys.last['v'];
    for (var i = 0; i + 1 < keys.length; i += 1) {
      final t0 = _time(keys[i]);
      final t1 = _time(keys[i + 1]);
      if (t >= t0 && t < t1) {
        final pRaw = (t - t0).seconds / (t1 - t0).seconds;
        final p = _ease(pRaw, (keys[i]['interp'] ?? 'linear') as String);
        return _lerp(keys[i]['v'], keys[i + 1]['v'], p);
      }
    }
    return keys.last['v'];
  }

  static double _ease(double p, String interp) => switch (interp) {
    'easeIn' => p * p,
    'easeOut' => 1.0 - (1.0 - p) * (1.0 - p),
    'easeInOut' => p * p * (3.0 - 2.0 * p),
    'hold' => 0.0,
    _ => p,
  };

  /// Numbers lerp; maps lerp per numeric key recursively; anything else holds
  /// left (right wins at p >= 1).
  static dynamic _lerp(dynamic a, dynamic b, double p) {
    if (p >= 1.0) return b;
    if (a is num && b is num) {
      return a + (b - a) * p;
    }
    if (a is Map && b is Map) {
      final out = <String, dynamic>{
        for (final e in a.entries)
          if (e.key is String) e.key as String: e.value,
      };
      for (final e in b.entries) {
        if (e.key is! String || !out.containsKey(e.key)) continue;
        out[e.key] = _lerp(out[e.key], e.value, p);
      }
      return out;
    }
    return a;
  }

  Map<String, dynamic> toJson() => {
    'static': static,
    if (animated)
      'keyframes': [
        for (final k in keyframes)
          {...k, 't': k['t']?.toString(), 'interp': k['interp'] ?? 'linear'},
      ],
  };

  static ParamValue fromJson(Map<String, dynamic>? j) =>
      j == null ? ParamValue.staticNum(0.0) : ParamValue.from(j);
}
