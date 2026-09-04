// GitHub Releases feed client for the updater.
//
// Trust model: TLS plus the offline Ed25519 signature, not the API alone.
// Every URL touched (API, redirects, asset downloads) must be https on an
// allowlisted host, manifests larger than 256 KB are rejected, and the
// detached signature in `latest.json.sig` is verified over the exact
// manifest bytes BEFORE any field is trusted. Any failure throws
// [UpdateFetchException] and the caller must fail closed.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../application/update_signature.dart';
import '../domain/update_keys.dart';
import '../domain/update_release.dart';
import 'update_check_result.dart';
import 'update_fetch_exception.dart';
import 'update_fetch_failure.dart';

class GitHubReleasesClient {
  GitHubReleasesClient({http.Client? client, String? apiUrl, Map<String, String>? verifyKeys})
    : _client = client ?? http.Client(),
      _apiUrl = apiUrl ?? latestApiUrl,
      _verifyKeys = verifyKeys ?? kUpdateVerifyKeys;

  /// Single place a fork changes to point the updater at its own releases.
  static const String owner = 'spix3l';
  static const String repo = 'crazycut';
  static const String latestApiUrl =
      'https://api.github.com/repos/spix3l/crazycut/releases/latest';
  static const String manifestName = 'latest.json';
  static const String signatureName = 'latest.json.sig';

  static const int maxManifestBytes = 256 * 1024;
  static const Duration requestTimeout = Duration(seconds: 10);
  static const int maxRedirects = 5;

  final http.Client _client;
  final String _apiUrl;

  /// Overrides the embedded production keys. Set only in tests; production
  /// always verifies against `kUpdateVerifyKeys`.
  final Map<String, String> _verifyKeys;

  /// Fetches, verifies, and parses the latest signed manifest.
  Future<UpdateCheckResult> fetchLatest() async {
    final apiUri = _validatedUri(_apiUrl, 'api');
    final body = await _getJson(apiUri);
    final assets = body['assets'];
    if (assets is! List) {
      throw const UpdateFetchException(
        UpdateFetchFailure.invalidManifest,
        'release has no assets list',
      );
    }
    final manifestUrl = _assetUrl(assets, manifestName);
    final signatureUrl = _assetUrl(assets, signatureName);
    if (manifestUrl == null || signatureUrl == null) {
      throw const UpdateFetchException(
        UpdateFetchFailure.notFound,
        'signed manifest assets are missing',
      );
    }
    final results = await Future.wait([
      _getBytes(_validatedUri(manifestUrl, 'manifest')),
      _getBytes(_validatedUri(signatureUrl, 'signature')),
    ]);
    final manifest = results[0];
    final signatureFile = utf8.decode(results[1], allowMalformed: true);
    final valid = await UpdateSignature.verify(
      message: manifest,
      signatureBase64: signatureFile.trim(),
      keys: _verifyKeys,
    );
    if (!valid) {
      throw const UpdateFetchException(
        UpdateFetchFailure.badSignature,
        'manifest signature did not verify',
      );
    }
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(utf8.decode(manifest));
      if (decoded is Map<String, dynamic>) json = decoded;
    } on FormatException {
      json = null;
    }
    if (json == null) {
      throw const UpdateFetchException(
        UpdateFetchFailure.invalidManifest,
        'manifest is not a JSON object',
      );
    }
    final problems = <String>[];
    final release = UpdateRelease.tryParse(json, errors: problems);
    if (release == null) {
      throw UpdateFetchException(
        UpdateFetchFailure.invalidManifest,
        problems.isEmpty ? 'manifest failed validation' : problems.first,
      );
    }
    return UpdateCheckResult(release: release, manifest: manifest);
  }

  String? _assetUrl(List<dynamic> assets, String name) {
    for (final entry in assets) {
      if (entry is Map<String, dynamic> &&
          entry['name'] == name &&
          entry['browser_download_url'] is String) {
        return entry['browser_download_url'] as String;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final bytes = await _getBytes(uri);
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException catch (e) {
      throw UpdateFetchException(
        UpdateFetchFailure.invalidManifest,
        'release JSON is malformed: $e',
      );
    }
    throw const UpdateFetchException(
      UpdateFetchFailure.invalidManifest,
      'release JSON is not an object',
    );
  }

  Uri _validatedUri(String raw, String what) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !uri.isAbsolute ||
        uri.scheme != 'https' ||
        !UpdateRelease.allowedHosts.contains(uri.host.toLowerCase())) {
      throw UpdateFetchException(
        UpdateFetchFailure.network,
        'disallowed $what URL',
      );
    }
    return uri;
  }

  /// GET with manual redirect handling so every hop is revalidated against
  /// the host allowlist. Rejects oversized bodies before buffering them.
  Future<Uint8List> _getBytes(Uri uri) async {
    var current = uri;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      final request = http.Request('GET', current)..followRedirects = false;
      request.headers['Accept'] = 'application/octet-stream';
      request.headers['User-Agent'] = 'CrazyCut-Updater';
      http.StreamedResponse response;
      try {
        response = await _client.send(request).timeout(requestTimeout);
      } on TimeoutException {
        throw const UpdateFetchException(
          UpdateFetchFailure.network,
          'request timed out',
        );
      } on Object catch (e) {
        throw UpdateFetchException(
          UpdateFetchFailure.network,
          'request failed: $e',
        );
      }
      if (_isRedirect(response.statusCode)) {
        if (hop == maxRedirects) {
          throw const UpdateFetchException(
            UpdateFetchFailure.network,
            'too many redirects',
          );
        }
        final location = response.headers['location'];
        // Drain before continuing so the connection is not leaked.
        await response.stream.drain<void>();
        if (location == null || location.isEmpty) {
          throw const UpdateFetchException(
            UpdateFetchFailure.network,
            'redirect without a location',
          );
        }
        Uri next;
        try {
          next = current.resolve(location);
        } on Object {
          throw const UpdateFetchException(
            UpdateFetchFailure.network,
            'redirect target is malformed',
          );
        }
        current = _validatedUri(next.toString(), 'redirect');
        continue;
      }
      if (response.statusCode == 404) {
        await response.stream.drain<void>();
        throw const UpdateFetchException(
          UpdateFetchFailure.notFound,
          'resource not found',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        throw UpdateFetchException(
          UpdateFetchFailure.network,
          'unexpected status ${response.statusCode}',
        );
      }
      final declared = response.contentLength;
      if (declared != null && declared > maxManifestBytes) {
        await response.stream.drain<void>();
        throw const UpdateFetchException(
          UpdateFetchFailure.tooLarge,
          'manifest exceeds size cap',
        );
      }
      final builder = BytesBuilder();
      try {
        await for (final chunk in response.stream.timeout(requestTimeout)) {
          builder.add(chunk);
          if (builder.length > maxManifestBytes) {
            throw const UpdateFetchException(
              UpdateFetchFailure.tooLarge,
              'manifest exceeds size cap',
            );
          }
        }
      } on TimeoutException {
        throw const UpdateFetchException(
          UpdateFetchFailure.network,
          'download timed out',
        );
      }
      return builder.takeBytes();
    }
    throw const UpdateFetchException(
      UpdateFetchFailure.network,
      'too many redirects',
    );
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;
}
