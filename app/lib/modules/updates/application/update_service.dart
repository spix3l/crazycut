// Update check, auto-download, and verified-install service.
//
// Flow: silent or manual check fetches the signed manifest, compares
// versions, then auto-downloads the per-OS asset in the background while
// reporting progress. The SHA-256 from the signed manifest is verified
// before anything is presented. Completion surfaces a "ready to install"
// state; the app NEVER mounts, extracts, executes, or relaunches anything.
// Installing stays a guided manual step (DMG drag, zip replace), which is
// the only safe option for the current DMG plus zip distribution.
//
// Failure policy: background checks fail silently back to idle (or stay on
// the current state), manual checks surface one friendly error message.
// A failed or cancelled download never touches the running install: bytes
// go to a `.part` file and are renamed only after the hash verifies.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'package:crazycut_app/modules/settings/application/ui_preferences.dart';

import '../domain/update_asset.dart';
import '../domain/update_release.dart';
import '../domain/update_version.dart';
import '../infrastructure/github_releases_client.dart';
import '../infrastructure/update_check_result.dart';
import '../infrastructure/update_fetch_exception.dart';
import '../infrastructure/update_fetch_failure.dart';
import 'update_status.dart';

class UpdateService extends ChangeNotifier {
  UpdateService({
    required this._preferences,
    GitHubReleasesClient? feed,
    http.Client? downloadClient,
    this._downloadDirOverride,
    this._currentVersionOverride,
  }) : _feed = feed ?? GitHubReleasesClient(),
       _downloadClient = downloadClient ?? http.Client();

  /// Shared instance used in production. The current version is read lazily
  /// from the stamped build (`--build-name` from the release tag).
  static final UpdateService instance = UpdateService(
    preferences: UiPreferences.instance,
  );

  final UiPreferences _preferences;
  final GitHubReleasesClient _feed;
  final http.Client _downloadClient;
  final Directory? _downloadDirOverride;
  final String? _currentVersionOverride;

  static const Duration checkInterval = Duration(hours: 24);
  static const Duration requestTimeout = Duration(seconds: 10);

  UpdateStatus _status = UpdateStatus.idle;
  UpdateRelease? _release;
  double _progress = 0;
  String _errorMessage = '';
  String _downloadedPath = '';
  bool _cancelRequested = false;
  Future<void>? _inflight;

  UpdateStatus get status => _status;
  UpdateRelease? get release => _release;
  double get progress => _progress;
  String get errorMessage => _errorMessage;
  String get downloadedPath => _downloadedPath;
  String get lastCheckedAt => _preferences.lastUpdateCheckAt;
  bool get autoCheck => _preferences.autoCheckUpdates;

  /// Resolved at check time so tests can inject an override.
  Future<String> currentVersionString() async {
    if (_currentVersionOverride != null) return _currentVersionOverride;
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } on Object {
      return '';
    }
  }

  UpdateVersion? _parseCurrent(String raw) {
    final cleaned = raw.trim().split('+').first;
    return UpdateVersion.tryParse(cleaned);
  }

  bool _throttled() {
    final raw = _preferences.lastUpdateCheckAt;
    if (raw.isEmpty) return false;
    try {
      final last = DateTime.parse(raw);
      return DateTime.now().toUtc().difference(last.toUtc()) < checkInterval;
    } on FormatException {
      return false;
    }
  }

  /// Checks for a newer release. Background callers pass
  /// `userInitiated: false` and get silence on any failure; manual callers
  /// get [UpdateStatus.upToDate] or [UpdateStatus.error] surfaced.
  /// A newer release starts downloading immediately (auto-download).
  Future<void> checkNow({bool userInitiated = false}) {
    if (_status == UpdateStatus.checking ||
        _status == UpdateStatus.downloading) {
      return _inflight ?? Future.value();
    }
    if (!userInitiated) {
      if (!_preferences.autoCheckUpdates || _throttled()) {
        return Future.value();
      }
    }
    _inflight = _check(userInitiated: userInitiated);
    return _inflight!;
  }

  Future<void> _check({required bool userInitiated}) async {
    _status = UpdateStatus.checking;
    _errorMessage = '';
    notifyListeners();
    UpdateCheckResult result;
    try {
      result = await _feed.fetchLatest();
    } on UpdateFetchException catch (e) {
      if (userInitiated) {
        _status = UpdateStatus.error;
        _errorMessage = _friendlyFetchError(e);
      } else {
        _status = UpdateStatus.idle;
      }
      notifyListeners();
      return;
    }
    _preferences.setLastUpdateCheckAt(DateTime.now().toUtc());

    final current = _parseCurrent(await currentVersionString());
    if (current == null) {
      // Dev builds without a stamped version must not prompt.
      _status = userInitiated ? UpdateStatus.error : UpdateStatus.idle;
      if (userInitiated) {
        _errorMessage =
            'The installed version could not be determined, '
            'so no update check is possible in this build.';
      }
      notifyListeners();
      return;
    }
    if (result.release.version <= current) {
      _status = userInitiated ? UpdateStatus.upToDate : UpdateStatus.idle;
      _release = null;
      notifyListeners();
      return;
    }
    if (!userInitiated &&
        _preferences.skippedUpdateVersion == result.release.tag) {
      _status = UpdateStatus.idle;
      _release = null;
      notifyListeners();
      return;
    }
    _release = result.release;
    _status = UpdateStatus.available;
    _progress = 0;
    notifyListeners();
    await _download();
  }

  /// Retries the download for the currently available release.
  Future<void> downloadRelease() async {
    if (_release == null || _status == UpdateStatus.downloading) return;
    _status = UpdateStatus.available;
    notifyListeners();
    await _download();
  }

  void cancelDownload() {
    _cancelRequested = true;
  }

  /// Remembers the current tag as skipped so background checks stop
  /// prompting until a newer release appears.
  void dismissVersion() {
    final tag = _release?.tag;
    if (tag != null && tag.isNotEmpty) {
      _preferences.setSkippedUpdateVersion(tag);
    }
    _release = null;
    _status = UpdateStatus.idle;
    _progress = 0;
    notifyListeners();
  }

  /// Forgets a previous skip (used after a successful download or when the
  /// user explicitly checks again).
  void clearSkip() {
    _preferences.setSkippedUpdateVersion('');
  }

  Future<Directory> _dir() async {
    final override = _downloadDirOverride;
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(
      '${support.path}${Platform.pathSeparator}updates',
    );
    await dir.create(recursive: true);
    return dir;
  }

  UpdateAsset _assetForPlatform() {
    final release = _release;
    if (release == null) throw StateError('no release to download');
    if (Platform.isMacOS) return release.macos;
    if (Platform.isWindows) return release.windows;
    // Linux and other dev hosts have no packaged artifact: fail closed.
    throw const UpdateFetchException(
      UpdateFetchFailure.invalidManifest,
      'no update asset for this platform',
    );
  }

  Future<void> _download() async {
    final release = _release;
    if (release == null) return;
    late final UpdateAsset asset;
    try {
      asset = _assetForPlatform();
    } on UpdateFetchException catch (e) {
      _status = UpdateStatus.error;
      _errorMessage = _friendlyFetchError(e);
      notifyListeners();
      return;
    }
    _status = UpdateStatus.downloading;
    _progress = 0;
    _cancelRequested = false;
    notifyListeners();

    late final Directory dir;
    try {
      dir = await _dir();
    } on Object {
      _status = UpdateStatus.error;
      _errorMessage = 'The update folder could not be created.';
      notifyListeners();
      return;
    }
    final target = File('${dir.path}${Platform.pathSeparator}${asset.file}');
    final part = File('${target.path}.part');

    // A verified complete file from an earlier run is reused as-is.
    if (await target.exists()) {
      try {
        if (await _sha256Of(target) == asset.sha256 &&
            await target.length() == asset.size) {
          _downloadedPath = target.path;
          _status = UpdateStatus.ready;
          notifyListeners();
          return;
        }
      } on Object {
        // Fall through to a fresh download.
      }
    }

    Uri uri;
    try {
      uri = _validatedDownloadUri(asset.url);
    } on UpdateFetchException catch (e) {
      _status = UpdateStatus.error;
      _errorMessage = _friendlyFetchError(e);
      notifyListeners();
      return;
    }

    http.StreamedResponse response;
    try {
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers['User-Agent'] = 'CrazyCut-Updater';
      response = await _downloadClient.send(request).timeout(requestTimeout);
    } on TimeoutException {
      return _failDownload(part, 'The download timed out. Try again.');
    } on Object {
      return _failDownload(part, 'The download could not start. Try again.');
    }

    // Follow redirects manually so every hop stays on the allowlist.
    var hops = 0;
    while (_isRedirect(response.statusCode)) {
      if (hops >= GitHubReleasesClient.maxRedirects) {
        await response.stream.drain<void>();
        return _failDownload(part, 'The download was redirected too often.');
      }
      final location = response.headers['location'];
      await response.stream.drain<void>();
      if (location == null || location.isEmpty) {
        return _failDownload(part, 'The download redirect was invalid.');
      }
      try {
        uri = _validatedDownloadUri(uri.resolve(location).toString());
      } on UpdateFetchException {
        return _failDownload(part, 'The download redirect was not allowed.');
      }
      try {
        final next = http.Request('GET', uri)..followRedirects = false;
        next.headers['User-Agent'] = 'CrazyCut-Updater';
        response = await _downloadClient.send(next).timeout(requestTimeout);
      } on Object {
        return _failDownload(part, 'The download could not start. Try again.');
      }
      hops++;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      return _failDownload(
        part,
        'The download failed (status ${response.statusCode}).',
      );
    }
    final declared = response.contentLength;
    if (declared != null && declared != asset.size) {
      await response.stream.drain<void>();
      return _failDownload(
        part,
        'The update file had an unexpected size and was discarded.',
      );
    }

    IOSink? sink;
    try {
      sink = part.openWrite();
      var received = 0;
      await for (final chunk in response.stream.timeout(requestTimeout)) {
        if (_cancelRequested) {
          await sink.close();
          _status = UpdateStatus.available;
          _progress = 0;
          notifyListeners();
          return;
        }
        received += chunk.length;
        if (received > asset.size) {
          await sink.close();
          return _failDownload(
            part,
            'The update file was larger than expected and was discarded.',
          );
        }
        sink.add(chunk);
        _progress = asset.size == 0 ? 0 : received / asset.size;
        notifyListeners();
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (received != asset.size) {
        return _failDownload(
          part,
          'The download was incomplete and was discarded.',
        );
      }
      if (await _sha256Of(part) != asset.sha256) {
        return _failDownload(
          part,
          'The update file failed its integrity check and was discarded. '
          'Try again, or download manually from GitHub.',
        );
      }
      await part.rename(target.path);
      _downloadedPath = target.path;
      clearSkip();
      _status = UpdateStatus.ready;
      _progress = 1;
      notifyListeners();
    } on TimeoutException {
      try {
        await sink?.close();
      } on Object {
        // Best effort cleanup.
      }
      return _failDownload(part, 'The download timed out. Try again.');
    } on Object {
      try {
        await sink?.close();
      } on Object {
        // Best effort cleanup.
      }
      return _failDownload(part, 'The download failed. Try again.');
    }
  }

  Future<void> _failDownload(File part, String message) async {
    try {
      if (await part.exists()) await part.delete();
    } on Object {
      // Best effort cleanup of a partial file.
    }
    _status = UpdateStatus.error;
    _errorMessage = message;
    _progress = 0;
    notifyListeners();
  }

  Future<String> _sha256Of(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Uri _validatedDownloadUri(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !uri.isAbsolute ||
        uri.scheme != 'https' ||
        !UpdateRelease.allowedHosts.contains(uri.host.toLowerCase())) {
      throw const UpdateFetchException(
        UpdateFetchFailure.network,
        'disallowed download URL',
      );
    }
    return uri;
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  static String _friendlyFetchError(UpdateFetchException e) {
    switch (e.failure) {
      case UpdateFetchFailure.network:
        return 'CrazyCut could not reach the update feed. '
            'Check the connection and try again.';
      case UpdateFetchFailure.notFound:
        return 'No signed update manifest was published for the latest '
            'release yet. Try again later.';
      case UpdateFetchFailure.tooLarge:
        return 'The update manifest was unexpectedly large and was ignored.';
      case UpdateFetchFailure.badSignature:
        return 'The update manifest failed its signature check and was '
            'discarded. Download manually from GitHub if this persists.';
      case UpdateFetchFailure.invalidManifest:
        return 'The update information was invalid and was discarded.';
    }
  }
}
