import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/updates/domain/update_release.dart';

Map<String, dynamic> validManifest() => {
  'tag': 'v0.3.0',
  'version': '0.3.0',
  'published_at': '2026-09-04T00:00:00Z',
  'notes': 'Bug fixes.',
  'release_page_url': 'https://github.com/spix3l/crazycut/releases/tag/v0.3.0',
  'assets': {
    'macos': {
      'file': 'CrazyCut.dmg',
      'url': 'https://objects.githubusercontent.com/crazycut/CrazyCut.dmg',
      'sha256': 'a' * 64,
      'size': 200 * 1024 * 1024,
    },
    'windows': {
      'file': 'CrazyCut-Windows.zip',
      'url': 'https://objects.githubusercontent.com/crazycut/win.zip',
      'sha256': 'b' * 64,
      'size': 210 * 1024 * 1024,
    },
  },
};

void main() {
  group('UpdateRelease.tryParse', () {
    test('accepts a well formed manifest', () {
      final release = UpdateRelease.tryParse(validManifest());
      expect(release, isNotNull);
      expect(release!.tag, 'v0.3.0');
      expect(release.version.toString(), '0.3.0');
      expect(release.macos.file, 'CrazyCut.dmg');
      expect(release.windows.file, 'CrazyCut-Windows.zip');
    });

    test('truncates overlong notes instead of rejecting', () {
      final json = validManifest()..['notes'] = 'x' * 5000;
      final release = UpdateRelease.tryParse(json);
      expect(release, isNotNull);
      expect(release!.notes.length, UpdateRelease.maxNotesLength);
    });

    test('rejects untrustworthy manifests', () {
      final cases = <String, Map<String, dynamic> Function()>{
        'prerelease tag': () => validManifest()..['tag'] = 'v0.3.0-rc.1',
        'version/tag mismatch':
            () => validManifest()..['version'] = '0.4.0',
        'http asset url':
            () => validManifest()
              ..['assets'] = {
                'macos': {
                  'file': 'CrazyCut.dmg',
                  'url': 'http://example.com/CrazyCut.dmg',
                  'sha256': 'a' * 64,
                  'size': 200 * 1024 * 1024,
                },
                'windows': (validManifest()['assets']
                    as Map)['windows'],
              },
        'evil host':
            () => validManifest()
              ..['assets'] = {
                'macos': {
                  'file': 'CrazyCut.dmg',
                  'url': 'https://evil.example.com/CrazyCut.dmg',
                  'sha256': 'a' * 64,
                  'size': 200 * 1024 * 1024,
                },
                'windows': (validManifest()['assets']
                    as Map)['windows'],
              },
        'short sha':
            () => validManifest()
              ..['assets'] = {
                'macos': {
                  'file': 'CrazyCut.dmg',
                  'url':
                      'https://objects.githubusercontent.com/crazycut/a.dmg',
                  'sha256': 'abc',
                  'size': 200 * 1024 * 1024,
                },
                'windows': (validManifest()['assets']
                    as Map)['windows'],
              },
        'renamed file':
            () => validManifest()
              ..['assets'] = {
                'macos': {
                  'file': 'CrazyCut-Setup.exe',
                  'url':
                      'https://objects.githubusercontent.com/crazycut/a.exe',
                  'sha256': 'a' * 64,
                  'size': 200 * 1024 * 1024,
                },
                'windows': (validManifest()['assets']
                    as Map)['windows'],
              },
        'tiny size':
            () => validManifest()
              ..['assets'] = {
                'macos': {
                  'file': 'CrazyCut.dmg',
                  'url':
                      'https://objects.githubusercontent.com/crazycut/a.dmg',
                  'sha256': 'a' * 64,
                  'size': 12,
                },
                'windows': (validManifest()['assets']
                    as Map)['windows'],
              },
        'future date':
            () => validManifest()
              ..['published_at'] = '2999-01-01T00:00:00Z',
        'missing windows asset':
            () => validManifest()
              ..['assets'] = {
                'macos': (validManifest()['assets'] as Map)['macos'],
              },
      };
      for (final entry in cases.entries) {
        expect(
          UpdateRelease.tryParse(entry.value()),
          isNull,
          reason: 'should reject: ${entry.key}',
        );
      }
    });
  });

  group('isAllowedUrl', () {
    test('only https on the allowlist passes', () {
      expect(
        UpdateRelease.isAllowedUrl('https://api.github.com/repos/a/b'),
        isTrue,
      );
      expect(
        UpdateRelease.isAllowedUrl(
          'https://objects.githubusercontent.com/a/b.dmg',
        ),
        isTrue,
      );
      expect(UpdateRelease.isAllowedUrl('http://github.com/a'), isFalse);
      expect(
        UpdateRelease.isAllowedUrl('https://evil.example.com/a'),
        isFalse,
      );
      expect(UpdateRelease.isAllowedUrl('not a url'), isFalse);
    });
  });
}
