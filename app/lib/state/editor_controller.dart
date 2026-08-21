import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'package:crazycut_app/data/autosave.dart';
import 'package:crazycut_app/data/media_cache.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/proxy_service.dart';
import 'package:crazycut_app/state/timeline_edits.dart';

enum ImportStatus { probing, ready, failed, offline }

class PoolItem {
  PoolItem({required this.asset, this.status = ImportStatus.probing, this.thumb});
  final MediaAsset asset;
  ImportStatus status;
  Uint8List? thumb;
}

/// Files we accept (IMP: supported formats).
const kSupportedExtensions = {
  'mp4', 'mov', 'mkv', 'webm', 'm4v',
  'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg',
  'png', 'jpg', 'jpeg', 'webp', 'gif',
};

/// Everything the editor screen reads and writes for one open project:
/// document edits (via [TimelineEdits]), the media pool, playback, the preview
/// frame, autosave and proxies.
class EditorController extends ChangeNotifier with TimelineEdits {
  EditorController(this.doc, {required String path, ProxyService? proxies})
      : proxies = proxies ?? ProxyService() {
    autosave = ProjectAutosave(doc, path: path, onStateChanged: (_) => notifyListeners());
    this.proxies.addListener(notifyListeners);
    for (final asset in doc.media) {
      final exists = asset.path.isNotEmpty && File(asset.path).existsSync();
      asset.offline = !exists;
      pool[asset.id] = PoolItem(
        asset: asset,
        status: exists ? ImportStatus.ready : ImportStatus.offline,
      );
      if (exists) this.proxies.request(asset);
    }
    _syncEngineGraph();
    unawaited(_warmThumbnails());
    unawaited(updatePreviewFrame());
  }

  @override
  final ProjectDoc doc;

  late final ProjectAutosave autosave;
  final ProxyService proxies;

  @override
  Rt playhead = Rt.zero();

  bool playing = false;
  bool looping = false;
  Timer? _playTimer;
  bool _frameBusy = false;
  double _shuttleRate = 1;

  final Map<String, PoolItem> pool = {};
  Uint8List? previewFrame;
  double previewFrameTime = -1;

  /// Names skipped on the last import (IMP-4).
  List<String> lastSkipped = const [];

  static const int previewWidth = 640;

  @override
  double get fps => doc.settings.fpsValue;

  double get shuttleRate => _shuttleRate;
  String get path => autosave.path;
  SaveState get saveState => autosave.state;
  bool get isDirty => autosave.isDirty;

  Rt get duration => doc.sequenceDuration;

  /// Playback range: in/out when set, else the whole sequence (TIM-12).
  Rt get rangeStart => inPoint ?? Rt.zero();
  Rt get rangeEnd => outPoint ?? duration;

  String get timecode => Rt.toTimecode(playhead, fps);
  String get durationTimecode => Rt.toTimecode(duration, fps);

  @override
  void dispose() {
    _playTimer?.cancel();
    proxies.removeListener(notifyListeners);
    proxies.dispose();
    autosave.dispose();
    super.dispose();
  }

  Future<void> close() async {
    _playTimer?.cancel();
    playing = false;
    await autosave.close();
  }

  // --- Media pool -----------------------------------------------------------

  /// Expands folders, drops unsupported files and imports the rest (IMP-1/2/4).
  Future<void> importPaths(List<String> paths) async {
    final files = <String>[];
    final skipped = <String>[];
    for (final path in paths) {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        for (final entity in Directory(path).listSync(recursive: true)) {
          if (entity is! File) continue;
          _supported(entity.path) ? files.add(entity.path) : null;
        }
      } else if (_supported(path)) {
        files.add(path);
      } else {
        skipped.add(path.split(Platform.pathSeparator).last);
      }
    }
    lastSkipped = skipped;
    if (files.isNotEmpty) await importFiles(files);
    if (skipped.isNotEmpty) notifyListeners();
  }

  bool _supported(String path) =>
      kSupportedExtensions.contains(path.split('.').last.toLowerCase());

  Future<void> importFiles(List<String> paths, {bool addToTimeline = true}) async {
    for (final path in paths) {
      final name = path.split(Platform.pathSeparator).last;
      final asset = MediaAsset(
        id: generateId(),
        name: name,
        path: path,
        type: 'video',
        duration: Rt.zero(),
        hasAudio: true,
      );
      pool[asset.id] = PoolItem(asset: asset);
      notifyListeners();
      try {
        final probe = CrazyCutEngine.instance.probeFile(path);
        final hash = CrazyCutEngine.instance.hashFile(path);
        final duplicate = doc.media.firstWhereOrNull((item) => item.hash == hash);
        if (duplicate != null) {
          // IMP-3: re-importing the same content selects the existing asset.
          pool.remove(asset.id);
          pool[duplicate.id] = PoolItem(asset: duplicate, status: ImportStatus.ready);
          notifyListeners();
          continue;
        }
        asset.hash = hash;
        asset.type = probe.type == 'unknown' ? 'video' : probe.type;
        asset.duration = Rt.fromSeconds(probe.durationSeconds);
        asset.hasAudio = probe.hasAudio;
        asset.width = probe.width;
        asset.height = probe.height;
        asset.fps = probe.fps;
        asset.rotation = probe.rotation;
        asset.vfr = probe.vfr;
        asset.codec = probe.codec;
        asset.hdr = probe.hdr;
        asset.thumbStatus = ThumbStatus.pending;
        doc.media.add(asset);
        pool[asset.id]!.status = ImportStatus.ready;
        proxies.request(asset);
        unawaited(_loadThumbnailInto(pool[asset.id]!));
        if (addToTimeline) placeAsset(asset.id);
      } catch (e) {
        pool[asset.id]?.status = ImportStatus.failed;
        debugPrint('import failed for $path: $e');
      }
    }
    markDirty();
    notifyListeners();
  }

  /// IMP-12: removing an asset never touches the file on disk.
  void removeAsset(String assetId, {bool force = false}) {
    final asset = doc.assetById(assetId);
    if (asset == null) return;
    final used = doc.usageCount(assetId);
    if (used > 0 && !force) return;
    deleteClips(doc.clips.where((c) => c.mediaId == assetId).map((c) => c.id).toList());
    doc.media.remove(asset);
    pool.remove(assetId);
    markDirty();
    notifyListeners();
  }

  /// IMP-16 relink: repoint an asset at a new file.
  Future<void> relinkAsset(String assetId, String newPath) async {
    final asset = doc.assetById(assetId);
    if (asset == null) return;
    asset.path = newPath;
    asset.offline = !File(newPath).existsSync();
    pool[assetId]?.status = asset.offline ? ImportStatus.offline : ImportStatus.ready;
    if (!asset.offline) {
      proxies.request(asset);
      unawaited(_loadThumbnailInto(pool[assetId]!));
    }
    markDirty();
    notifyListeners();
  }

  List<MediaAsset> get offlineAssets => doc.media.where((a) => a.offline).toList();

  /// IMP-12 "Reveal in folder" — Finder/Explorer, never a modal.
  Future<void> revealAsset(String assetId) async {
    final asset = doc.assetById(assetId);
    if (asset == null) return;
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', asset.path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', asset.path]);
      } else {
        await Process.run('xdg-open', [File(asset.path).parent.path]);
      }
    } on Object catch (error) {
      debugPrint('reveal failed: $error');
    }
  }

  Future<void> _warmThumbnails() async {
    for (final item in pool.values.toList()) {
      await _loadThumbnailInto(item);
    }
  }

  Future<void> _loadThumbnailInto(PoolItem item) async {
    if (item.thumb != null || item.asset.type == 'audio' || item.asset.offline) return;
    final bytes = await MediaCache.instance.thumb(
      item.asset,
      item.asset.duration.seconds > 2 ? 1.0 : 0.0,
      width: 320,
    );
    if (bytes == null) return;
    item.thumb = bytes;
    item.asset.thumbStatus = ThumbStatus.ready;
    notifyListeners();
  }

  /// Filmstrip tile for a clip at [sourceSeconds] (TIM-14). Returns null while
  /// the decode is in flight and repaints when it arrives.
  Uint8List? filmstripTile(MediaAsset asset, double sourceSeconds, {int width = 160}) {
    if (asset.offline) return null;
    final quantised = (sourceSeconds * 2).floor() / 2;
    final cached = MediaCache.instance.thumbNow(asset, quantised, width: width);
    if (cached != null) return cached;
    unawaited(MediaCache.instance
        .thumb(asset, quantised, width: width, onReady: notifyListeners));
    return null;
  }

  /// Peak envelope for an audio-bearing asset (IMP-7); empty until it lands.
  List<double> waveformFor(MediaAsset asset) {
    if (asset.offline) return const [];
    final cached = MediaCache.instance.peaksNow(asset);
    if (cached != null) return cached;
    unawaited(MediaCache.instance.peaks(asset, onReady: notifyListeners));
    return const [];
  }

  // --- Playback / navigation ------------------------------------------------

  void seekTo(Rt t) {
    var clamped = t < Rt.zero() ? Rt.zero() : t;
    if (clamped == playhead) return;
    playhead = clamped;
    notifyListeners();
    unawaited(updatePreviewFrame());
  }

  void stepFrames(int frames) =>
      seekTo(playhead.plus(Rt.fromMicros(frameDuration.micros * frames)));

  void jumpToEdge({required bool forward}) {
    final edge = nextEdge(playhead, forward: forward);
    if (edge != null) seekTo(edge);
  }

  void jumpToMarker({required bool forward}) {
    final marker = nextMarker(playhead, forward: forward);
    if (marker != null) seekTo(marker);
  }

  void goToStart() => seekTo(rangeStart);
  void goToEnd() => seekTo(rangeEnd);

  void togglePlay() => playing ? stopPlayback() : play();

  /// J/L shuttle: repeated presses accelerate 1×→2×→4×→8×; K+L creeps at ¼
  /// speed (TIM-13).
  void shuttle({required bool forward, bool slow = false}) {
    final sign = forward ? 1.0 : -1.0;
    if (slow) {
      _shuttleRate = 0.25 * sign;
    } else if (playing && _shuttleRate.sign == sign) {
      _shuttleRate = (_shuttleRate.abs() * 2).clamp(1.0, 8.0) * sign;
    } else {
      _shuttleRate = sign;
    }
    play(rate: _shuttleRate);
  }

  void play({double rate = 1}) {
    _shuttleRate = rate;
    playing = true;
    if (playhead >= rangeEnd && rate > 0) seekTo(rangeStart);
    final tickMs = (1000 / (fps <= 0 ? 30 : fps)).round().clamp(10, 250);
    _playTimer?.cancel();
    _playTimer = Timer.periodic(Duration(milliseconds: tickMs), (_) {
      final step = Rt.fromMicros((frameDuration.micros * _shuttleRate).round());
      final next = playhead.plus(step);
      final end = rangeEnd;
      if (next < rangeStart && _shuttleRate < 0) {
        seekTo(rangeStart);
        stopPlayback();
        return;
      }
      if (!end.isZero && next > end) {
        if (looping) {
          seekTo(rangeStart);
          return;
        }
        seekTo(end);
        stopPlayback();
        return;
      }
      seekTo(next);
    });
    notifyListeners();
  }

  void stopPlayback() {
    _playTimer?.cancel();
    _playTimer = null;
    playing = false;
    _shuttleRate = 1;
    notifyListeners();
  }

  void toggleLoop() {
    looping = !looping;
    notifyListeners();
  }

  /// Topmost visible video clip under the playhead.
  Clip? clipUnderPlayhead() {
    final tracks = doc.videoTracks.where((t) => !t.hidden).toList().reversed;
    for (final track in tracks) {
      final hit = doc.clipsOn(track.id).firstWhereOrNull(
            (c) => playhead >= c.start && playhead < c.end,
          );
      if (hit != null) return hit;
    }
    return null;
  }

  Future<void> updatePreviewFrame() async {
    if (_frameBusy) return;
    final clip = clipUnderPlayhead();
    if (clip == null) {
      if (previewFrame != null) {
        previewFrame = null;
        previewFrameTime = -1;
        notifyListeners();
      }
      return;
    }
    final asset = doc.assetById(clip.mediaId);
    if (asset == null || asset.offline) return;
    _frameBusy = true;
    try {
      final localSeconds = playhead.minus(clip.start).seconds * clip.speedValue;
      final sourceSeconds = clip.sourceIn.seconds + localSeconds;
      previewFrame = CrazyCutEngine.instance.extractThumbnail(
        ProxyService.decodePath(asset),
        seconds: sourceSeconds,
        width: previewWidth,
      );
      previewFrameTime = playhead.seconds;
      notifyListeners();
    } catch (e) {
      debugPrint('preview frame failed: $e');
    } finally {
      _frameBusy = false;
    }
  }

  // --- Persistence ----------------------------------------------------------

  @override
  void markDirty() {
    // Mid-drag the document changes every frame; the engine only needs the
    // committed result, which endGesture() delivers.
    if (!inGesture) _syncEngineGraph();
    autosave.markDirty();
  }

  void _syncEngineGraph() {
    try {
      CrazyCutEngine.instance.setProjectSnapshot(doc.encode(touchModified: false));
    } catch (e) {
      debugPrint('engine graph sync failed: $e');
    }
  }

  Future<void> saveNow() => autosave.saveNow();

  /// PRJ-9 "Save a copy…".
  Future<File> saveCopy(String destination) =>
      ProjectRepository.saveCopy(doc, destination);

  Future<void> rename(String name) async {
    if (name.trim().isEmpty || name == doc.name) return;
    final target = await ProjectRepository.rename(path, name.trim());
    doc.name = name.trim();
    autosave.path = target.path;
    notifyListeners();
  }
}
