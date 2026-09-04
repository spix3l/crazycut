import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:crazycut_app/modules/updates/infrastructure/github_releases_client.dart';
import 'package:crazycut_app/modules/updates/infrastructure/update_fetch_exception.dart';
import 'package:crazycut_app/modules/updates/infrastructure/update_fetch_failure.dart';

const _api = GitHubReleasesClient.latestApiUrl;
const _manifestUrl = 'https://objects.githubusercontent.com/t/latest.json';
const _sigUrl = 'https://objects.githubusercontent.com/t/latest.json.sig';

Future<({Map<String, String> keys, Uint8List manifest, String signature})>
signedManifest() async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final manifest = Uint8List.fromList(utf8.encode(jsonEncode({
    'tag': 'v0.3.0',
    'version': '0.3.0',
    'published_at': '2026-09-04T00:00:00Z',
    'notes': 'Test.',
    'release_page_url':
        'https://github.com/spix3l/crazycut/releases/tag/v0.3.0',
    'assets': {
      'macos': {
        'file': 'CrazyCut.dmg',
        'url': 'https://objects.githubusercontent.com/t/CrazyCut.dmg',
        'sha256': 'a' * 64,
        'size': 2 * 1024 * 1024,
      },
      'windows': {
        'file': 'CrazyCut-Windows.zip',
        'url': 'https://objects.githubusercontent.com/t/CrazyCut-Windows.zip',
        'sha256': 'b' * 64,
        'size': 2 * 1024 * 1024,
      },
    },
  })));
  final signature = await algorithm.sign(manifest, keyPair: keyPair);
  return (
    keys: {'test': base64Encode(publicKey.bytes)},
    manifest: manifest,
    signature: base64Encode(signature.bytes),
  );
}

String releaseJson({String manifestUrl = _manifestUrl}) => jsonEncode({
  'assets': [
    {'name': 'latest.json', 'browser_download_url': manifestUrl},
    {'name': 'latest.json.sig', 'browser_download_url': _sigUrl},
  ],
});

void main() {
  group('GitHubReleasesClient', () {
    test('fetches and verifies the signed manifest', () async {
      final fixture = await signedManifest();
      final client = GitHubReleasesClient(
        client: MockClient((request) async {
          final url = request.url.toString();
          if (url == _api) return http.Response(releaseJson(), 200);
          if (url == _manifestUrl) {
            return http.Response.bytes(fixture.manifest, 200);
          }
          if (url == _sigUrl) return http.Response(fixture.signature, 200);
          return http.Response('not found', 404);
        }),
        verifyKeys: fixture.keys,
      );
      final result = await client.fetchLatest();
      expect(result.release.tag, 'v0.3.0');
    });

    test('follows allowlisted redirects', () async {
      final fixture = await signedManifest();
      const hop = 'https://github.com/t/latest.json';
      final client = GitHubReleasesClient(
        client: MockClient((request) async {
          final url = request.url.toString();
          if (url == _api) {
            return http.Response(releaseJson(manifestUrl: hop), 200);
          }
          if (url == hop) {
            return http.Response.bytes(
              fixture.manifest,
              302,
              headers: {'location': _manifestUrl},
            );
          }
          if (url == _manifestUrl) {
            return http.Response.bytes(fixture.manifest, 200);
          }
          if (url == _sigUrl) return http.Response(fixture.signature, 200);
          return http.Response('not found', 404);
        }),
        verifyKeys: fixture.keys,
      );
      final result = await client.fetchLatest();
      expect(result.release.tag, 'v0.3.0');
    });

    test('rejects redirects off the allowlist', () async {
      final fixture = await signedManifest();
      final client = GitHubReleasesClient(
        client: MockClient((request) async {
          final url = request.url.toString();
          if (url == _api) return http.Response(releaseJson(), 200);
          if (url == _manifestUrl) {
            return http.Response.bytes(
              fixture.manifest,
              302,
              headers: {'location': 'https://evil.example.com/latest.json'},
            );
          }
          if (url == _sigUrl) return http.Response(fixture.signature, 200);
          return http.Response('not found', 404);
        }),
        verifyKeys: fixture.keys,
      );
      expect(
        client.fetchLatest(),
        throwsA(
          isA<UpdateFetchException>().having(
            (e) => e.failure,
            'failure',
            UpdateFetchFailure.network,
          ),
        ),
      );
    });

    test('reports missing manifest assets as not found', () async {
      final fixture = await signedManifest();
      final client = GitHubReleasesClient(
        client: MockClient((request) async {
          if (request.url.toString() == _api) {
            return http.Response(jsonEncode({'assets': []}), 200);
          }
          return http.Response('not found', 404);
        }),
        verifyKeys: fixture.keys,
      );
      expect(
        client.fetchLatest(),
        throwsA(
          isA<UpdateFetchException>().having(
            (e) => e.failure,
            'failure',
            UpdateFetchFailure.notFound,
          ),
        ),
      );
    });

    test('rejects oversized manifests before buffering', () async {
      final fixture = await signedManifest();
      final big = Uint8List(
        GitHubReleasesClient.maxManifestBytes + 1024,
      );
      final client = GitHubReleasesClient(
        client: MockClient((request) async {
          final url = request.url.toString();
          if (url == _api) return http.Response(releaseJson(), 200);
          if (url == _manifestUrl) return http.Response.bytes(big, 200);
          if (url == _sigUrl) return http.Response(fixture.signature, 200);
          return http.Response('not found', 404);
        }),
        verifyKeys: fixture.keys,
      );
      expect(
        client.fetchLatest(),
        throwsA(
          isA<UpdateFetchException>().having(
            (e) => e.failure,
            'failure',
            UpdateFetchFailure.tooLarge,
          ),
        ),
      );
    });
  });
}
