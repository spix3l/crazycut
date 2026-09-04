import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/updates/domain/update_version.dart';

void main() {
  group('UpdateVersion.tryParse', () {
    test('accepts plain and v-prefixed triples', () {
      expect(UpdateVersion.tryParse('0.3.0').toString(), '0.3.0');
      expect(UpdateVersion.tryParse('v1.2.3').toString(), '1.2.3');
    });

    test('rejects prereleases, builds, partials, and garbage', () {
      for (final bad in [
        '',
        'v0.3',
        '0.3',
        'v0.3.0-rc.1',
        '0.3.0+build',
        'v1.2.3.4',
        'latest',
        'vX.Y.Z',
      ]) {
        expect(
          UpdateVersion.tryParse(bad),
          isNull,
          reason: 'should reject $bad',
        );
      }
    });
  });

  group('ordering', () {
    test('compares numerically per component, not lexicographically', () {
      final v039 = UpdateVersion.tryParse('v0.3.0')!;
      expect(UpdateVersion.tryParse('0.9.9')! < v039, isFalse);
      expect(UpdateVersion.tryParse('0.2.9')! < v039, isTrue);
      expect(UpdateVersion.tryParse('0.3.0')! == v039, isTrue);
      expect(UpdateVersion.tryParse('0.3.1')! > v039, isTrue);
      expect(UpdateVersion.tryParse('0.10.0')! > v039, isTrue);
      expect(UpdateVersion.tryParse('1.0.0')! > v039, isTrue);
    });
  });

  group('isStableTag', () {
    test('only vX.Y.Z release tags qualify', () {
      expect(UpdateVersion.isStableTag('v0.3.0'), isTrue);
      expect(UpdateVersion.isStableTag('0.3.0'), isFalse);
      expect(UpdateVersion.isStableTag('v0.3.0-rc.1'), isFalse);
      expect(UpdateVersion.isStableTag('latest'), isFalse);
    });
  });
}
