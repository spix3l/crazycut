class Rt implements Comparable<Rt> {
  factory Rt(int n, int d) {
    assert(d > 0, 'den must be positive');
    if (d < 0) {
      d = -d;
      n = -n;
    }
    final g = _gcd(n, d);
    return Rt._raw(g > 1 ? n ~/ g : n, g > 1 ? d ~/ g : d);
  }

  Rt._raw(this.num, this.den);

  factory Rt.zero() => Rt._raw(0, 1);

  factory Rt.parse(String text) {
    final slash = text.indexOf('/');
    if (slash < 0) throw FormatException('invalid rational time: $text');
    final n = int.parse(text.substring(0, slash));
    final d = int.parse(text.substring(slash + 1));
    if (d <= 0) throw FormatException('invalid rational time: $text');
    return Rt(n, d);
  }

  factory Rt.fromMicros(int micros) => _normalize(micros, 1000000);

  factory Rt.fromSeconds(double seconds) =>
      Rt.fromMicros((seconds * 1000000).round());

  static int _gcd(int a, int b) {
    while (b != 0) {
      final t = b;
      b = a % b;
      a = t;
    }
    return a.abs();
  }

  static Rt _normalize(int n, int d) => Rt(n, d);

  final int num;
  final int den;

  bool get isZero => num == 0;
  double get seconds => num / den;
  int get micros => (num * 1000000) ~/ den;

  Rt plus(Rt other) =>
      _normalize(num * other.den + other.num * den, den * other.den);
  Rt minus(Rt other) =>
      _normalize(num * other.den - other.num * den, den * other.den);

  Rt operator +(Rt other) => plus(other);
  Rt operator -(Rt other) => minus(other);

  @override
  String toString() => '$num/$den';

  @override
  int compareTo(Rt other) {
    final l = num * other.den;
    final r = other.num * den;
    return l.compareTo(r);
  }

  bool operator <(Rt other) => compareTo(other) < 0;
  bool operator >(Rt other) => compareTo(other) > 0;
  bool operator <=(Rt other) => compareTo(other) <= 0;
  bool operator >=(Rt other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is Rt && num * other.den == other.num * den;

  @override
  int get hashCode => Object.hash(num * 1000003, den);

  static String fpsToString(double fps) {
    const ntsc = [23.976, 29.97, 47.952, 59.94];
    for (final f in ntsc) {
      if ((fps - f).abs() < 0.01) {
        return '${(f * 1000).round()}/1001';
      }
    }
    return '${fps.round()}/1';
  }

  static double fpsFromString(String s) {
    final r = Rt.parse(s);
    return r.num / r.den;
  }

  static String toTimecode(Rt t, double fps) {
    final totalMicros = t.micros.abs();
    final h = totalMicros ~/ 3600000000;
    final m = (totalMicros ~/ 60000000) % 60;
    final s = (totalMicros ~/ 1000000) % 60;
    final frames =
        ((totalMicros % 1000000) / 1000000 * (fps <= 0 ? 30 : fps)).floor();
    String two(int v) => v.toString().padLeft(2, '0');
    final prefix = t.num < 0 ? '-' : '';
    return '$prefix${two(h)}:${two(m)}:${two(s)}:${two(frames)}';
  }
}
