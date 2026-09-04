import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:crazycut_app/modules/settings/application/ui_preferences.dart';
import 'package:crazycut_app/modules/updates/application/update_service.dart';
import 'package:crazycut_app/modules/updates/application/update_status.dart';
import 'package:crazycut_app/modules/updates/infrastructure/github_releases_client.dart';

const _manifestUrl = 'https://objects.githubusercontent.com/t/latest.json';
const _sigUrl = 'https://objects.githubusercontent.com/t/latest.json.sig';
const _dmgUrl = 'https://objects.githubusercontent.com/t/CrazyCut.dmg';
const _zipUrl = 'https://objects.githubusercontent.com/t/CrazyCut-Windows.zip';

bool get _hasDesktopAsset => Platform.isMacOS || Platform.isWindows;

String get _expectedFile =>
    Platform.isMacOS ? 'CrazyCut.dmg' : 'CrazyCut-Windows.zip';

/// Test signing identity plus a manifest whose asset hashes match [payload].
Future<({
  Map<String, String> keys,
  Uint8List manifest,
  String signature,
  Uint8List payload,
})>
signedFixture({int payloadBytes = 2 * 1024 * 1024}) async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final payload = Uint8List.fromList(
    List.generate(payloadBytes, (i) => i % 251),
  );
  final digest = sha256.convert(payload).toString();
  final manifest = Uint8List.fromList(utf8.encode(jsonEncode({
    'tag': 'v0.3.0',
    'version': '0.3.0',
    'published_at': '2026-09-04T00:00:00Z',
    'notes': 'Test release.',
    'release_page_url':
        'https://github.com/spix3l/crazycut/releases/tag/v0.3.0',
    'assets': {
      'macos': {
        'file': 'CrazyCut.dmg',
        'url': _dmgUrl,
        'sha256': digest,
        'size': payload.length,
      },
      'windows': {
        'file': 'CrazyCut-Windows.zip',
        'url': _zipUrl,
        'sha256': digest,
        'size': payload.length,
      },
    },
  })));
  final signature = await algorithm.sign(manifest, keyPair: keyPair);
  return (
    keys: {'test': base64Encode(publicKey.bytes)},
    manifest: manifest,
    signature: base64Encode(signature.bytes),
    payload: payload,
  );
}

String releaseJson() => jsonEncode({
  'html_url': 'https://github.com/spix3l/crazycut/releases/tag/v0.3.0',
  'assets': [
    {'name': 'latest.json', 'browser_download_url': _manifestUrl},
    {'name': 'latest.json.sig', 'browser_download_url': _sigUrl},
  ],
});

/// Feed mock serving one signed manifest; counts API hits for throttle tests.
MockClient feedClient({
  required Uint8List manifest,
  required String signature,
  required void Function() onApiHit,
  Uint8List? tamperedManifest,
}) {
  return MockClient((request) async {
    if (request.url.toString() == GitHubReleasesClient.latestApiUrl) {
      onApiHit();
      return http.Response(releaseJson(), 200);
    }
    if (request.url.toString() == _manifestUrl) {
      return http.Response.bytes(tamperedManifest ?? manifest, 200);
    }
    if (request.url.toString() == _sigUrl) {
      return http.Response(signature, 200);
    }
    return http.Response('not found', 404);
  });
}

MockClient downloadClient(Uint8List payload) {
  return MockClient((request) async {
    final url = request.url.toString();
    if (url == _dmgUrl || url == _zipUrl) {
      return http.Response.bytes(payload, 200);
    }
    return http.Response('not found', 404);
  });
}

Future<UiPreferences> testPreferences(
  Directory dir,
  List<UiPreferences> registry,
) async {
  final preferences = UiPreferences(storageDirOverride: dir);
  registry.add(preferences);
  await preferences.load();
  return preferences;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Directory downloads;
  late List<UiPreferences> prefsRegistry;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('crazycut-updates-');
    downloads = Directory('${dir.path}/downloads');
    await downloads.create();
    prefsRegistry = [];
  });

  tearDown(() async {
    // Preferences coalesce disk writes; flush before deleting the temp dir
    // or the recursive delete races an in-flight write.
    for (final prefs in prefsRegistry) {
      await prefs.flush();
    }
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  group('UpdateService', () {
    test('downloads, verifies, and reports ready', () async {
      final fixture = await signedFixture();
      var apiHits = 0;
      final preferences = await testPreferences(dir, prefsRegistry);
      final service = UpdateService(
        preferences: preferences,
        feed: GitHubReleasesClient(
          client: feedClient(
            manifest: fixture.manifest,
            signature: fixture.signature,
            onApiHit: () => apiHits++,
          ),
          verifyKeys: fixture.keys,
        ),
        downloadClient: downloadClient(fixture.payload),
        downloadDirOverride: downloads,
        currentVersionOverride: '0.1.0',
      );

      await service.checkNow(userInitiated: true);

      if (!_hasDesktopAsset) {
        expect(service.status, UpdateStatus.error);
        return;
      }
      expect(apiHits, 1);
      expect(service.status, UpdateStatus.ready);
      expect(service.release?.tag, 'v0.3.0');
      final file = File('${downloads.path}/$_expectedFile');
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), fixture.payload.length);
      // No partial file is left behind.
      expect(File('${file.path}.part').existsSync(), isFalse);
    });

    test('reports up to date when versions match', () async {
      final fixture = await signedFixture();
      final preferences = await testPreferences(dir, prefsRegistry);
      final service = UpdateService(
        preferences: preferences,
        feed: GitHubReleasesClient(
          client: feedClient(
            manifest: fixture.manifest,
            signature: fixture.signature,
            onApiHit: () {},
          ),
          verifyKeys: fixture.keys,
        ),
        downloadClient: downloadClient(fixture.payload),
        downloadDirOverride: downloads,
        currentVersionOverride: '0.3.0',
      );

      await service.checkNow(userInitiated: true);
      expect(service.status, UpdateStatus.upToDate);
      expect(service.release, isNull);
    });

    test('background check respects the 24h throttle', () async {
      final fixture = await signedFixture();
      var apiHits = 0;
      final preferences = await testPreferences(dir, prefsRegistry);
      preferences.setLastUpdateCheckAt(DateTime.now().toUtc());
      final service = UpdateService(
        preferences: preferences,
        feed: GitHubReleasesClient(
          client: feedClient(
            manifest: fixture.manifest,
            signature: fixture.signature,
            onApiHit: () => apiHits++,
          ),
          verifyKeys: fixture.keys,
        ),
        downloadClient: downloadClient(fixture.payload),
        downloadDirOverride: downloads,
        currentVersionOverride: '0.1.0',
      );

      await service.checkNow();
      expect(apiHits, 0);
      expect(service.status, UpdateStatus.idle);
    });

    test('background check stays off when opted out', () async {
      final fixture = await signedFixture();
      var apiHits = 0;
      final preferences = await testPreferences(dir, prefsRegistry);
      preferences.setAutoCheckUpdates(false);
      final service = UpdateService(
        preferences: preferences,
        feed: GitHubReleasesClient(
          client: feedClient(
            manifest: fixture.manifest,
            signature: fixture.signature,
            onApiHit: () => apiHits++,
          ),
          verifyKeys: fixture.keys,
        ),
        downloadClient: downloadClient(fixture.payload),
        downloadDirOverride: downloads,
        currentVersionOverride: '0.1.0',
      );

      await service.checkNow();
      expect(apiHits, 0);
      expect(service.status, UpdateStatus.idle);
    });

    test('bad signature stays silent in background, errors when manual',
        () async {
      final fixture = await signedFixture();
      Future<UpdateService> build() async {
        final preferences = await testPreferences(dir, prefsRegistry);
        return UpdateService(
          preferences: preferences,
          feed: GitHubReleasesClient(
            client: feedClient(
              manifest: fixture.manifest,
              signature: fixture.signature,
              tamperedManifest: Uint8List.fromList(
                utf8.encode('{"tag":"v9.9.9"}'),
              ),
              onApiHit: () {},
            ),
            verifyKeys: fixture.keys,
          ),
          downloadClient: downloadClient(fixture.payload),
          downloadDirOverride: downloads,
          currentVersionOverride: '0.1.0',
        );
      }

      final background = await build();
      await background.checkNow();
      expect(background.status, UpdateStatus.idle);
      expect(background.errorMessage, isEmpty);

      final manual = await build();
      await manual.checkNow(userInitiated: true);
      expect(manual.status, UpdateStatus.error);
      expect(manual.errorMessage, isNotEmpty);
    });

    test('skipped version suppresses background but not manual', () async {
      final fixture = await signedFixture();
      Future<UpdateService> build() async {
        final preferences = await testPreferences(dir, prefsRegistry);
        preferences.setSkippedUpdateVersion('v0.3.0');
        return UpdateService(
          preferences: preferences,
          feed: GitHubReleasesClient(
            client: feedClient(
              manifest: fixture.manifest,
              signature: fixture.signature,
              onApiHit: () {},
            ),
            verifyKeys: fixture.keys,
          ),
          downloadClient: downloadClient(fixture.payload),
          downloadDirOverride: downloads,
          currentVersionOverride: '0.1.0',
        );
      }

      final background = await build();
      await background.checkNow();
      expect(background.status, UpdateStatus.idle);

      final manual = await build();
      await manual.checkNow(userInitiated: true);
      if (_hasDesktopAsset) {
        expect(manual.status, UpdateStatus.ready);
      } else {
        expect(manual.status, UpdateStatus.error);
      }
    });

    test('oversized download is discarded and keeps no file', () async {
      final fixture = await signedFixture();
      final preferences = await testPreferences(dir, prefsRegistry);
      final oversized = Uint8List.fromList([
        ...fixture.payload,
        ...List.filled(16, 0),
      ]);
      final service = UpdateService(
        preferences: preferences,
        feed: GitHubReleasesClient(
          client: feedClient(
            manifest: fixture.manifest,
            signature: fixture.signature,
            onApiHit: () {},
          ),
          verifyKeys: fixture.keys,
        ),
        downloadClient: downloadClient(oversized),
        downloadDirOverride: downloads,
        currentVersionOverride: '0.1.0',
      );

      await service.checkNow(userInitiated: true);
      if (!_hasDesktopAsset) {
        expect(service.status, UpdateStatus.error);
        return;
      }
      expect(service.status, UpdateStatus.error);
      expect(service.downloadedPath, isEmpty);
      expect(downloads.listSync(), isEmpty);
    });

    test('cancel returns to available with no final file', () async {
      final fixture = await signedFixture();
      final preferences = await testPreferences(dir, prefsRegistry);
      final slow = _ChunkedClient(fixture.payload);
      final service = UpdateService(
        preferences: preferences,
        feed: GitHubReleasesClient(
          client: feedClient(
            manifest: fixture.manifest,
            signature: fixture.signature,
            onApiHit: () {},
          ),
          verifyKeys: fixture.keys,
        ),
        downloadClient: slow,
        downloadDirOverride: downloads,
        currentVersionOverride: '0.1.0',
      );

      if (!_hasDesktopAsset) {
        await service.checkNow(userInitiated: true);
        expect(service.status, UpdateStatus.error);
        return;
      }
      final checking = service.checkNow(userInitiated: true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      service.cancelDownload();
      await checking.timeout(const Duration(seconds: 15));
      expect(service.status, UpdateStatus.available);
      expect(service.downloadedPath, isEmpty);
      expect(
        File('${downloads.path}/$_expectedFile').existsSync(),
        isFalse,
      );
    });
  });
}

/// Download client that drips the payload in delayed chunks so cancellation
/// can land mid-download.
class _ChunkedClient extends http.BaseClient {
  _ChunkedClient(this.payload);

  final Uint8List payload;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    const chunk = 64 * 1024;
    final controller = StreamController<List<int>>();
    Future<void>(() async {
      for (var offset = 0; offset < payload.length; offset += chunk) {
        final end =
            (offset + chunk > payload.length) ? payload.length : offset + chunk;
        controller.add(payload.sublist(offset, end));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await controller.close();
    });
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: payload.length,
      request: request,
    );
  }
}
