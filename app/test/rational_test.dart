import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/models/rational.dart';

void main() {
  group('Rt', () {
    test('parses rational strings', () {
      final t = Rt.parse('450/3');
      expect(t.num, 150);
      expect(t.den, 1);
      expect(t.toString(), '150/1');
    });

    test('rejects invalid input', () {
      expect(() => Rt.parse('abc'), throwsFormatException);
      expect(() => Rt.parse('1/0'), throwsFormatException);
    });

    test('NTSC frames stay exact', () {
      expect(Rt.fromSeconds(5 * 1001 / 30000).micros, 166833);
      final a = Rt.parse('1001/30000');
      expect((a + a + a).toString(), '1001/10000');
    });

    test('comparison operators', () {
      expect(Rt.parse('250/1000') < Rt.parse('1/2'), isTrue);
      expect(Rt.parse('1/2') >= Rt.parse('50/100'), isTrue);
    });

    test('fps helpers', () {
      expect(Rt.fpsToString(29.97), '29970/1001');
      expect(Rt.fpsToString(30), '30/1');
      expect(Rt.fpsFromString('60000/1001'), closeTo(59.94, 0.001));
    });

    test('sequence duration math matches spec examples', () {
      final clipA = Rt.parse('0/1');
      final durA = Rt.fromSeconds(3.5);
      final end = clipA.plus(durA);
      expect(end.seconds, 3.5);
    });
  });
}
