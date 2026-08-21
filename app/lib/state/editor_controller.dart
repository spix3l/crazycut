import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/timeline_edits.dart';

enum ImportStatus { probing, ready, failed }

class PoolItem {
  PoolItem({required this.asset, this.status = ImportStatus.probing, this.thumb});
  final MediaAsset asset;
  ImportStatus status;
  Uint8List? thumb;
}

/// Everything the editor screen reads and writes for one open project:
/// document edits (via [TimelineEdits]), the media pool, playback and the
/// preview frame, plus autosave.
class EditorController extends ChangeNotifier with TimelineEdits {
  EditorController(this.doc) {
    for (final asset in doc.media) {
      pool[asset.id] = PoolItem(asset: asset, status: ImportStatus.ready);
    }
    _syncEngineGraph();
    unawaited(_warmThumbnails());
    // Show the frame at 0 straight away instead of waiting for a first seek.
    unawaited(updatePreviewFrame());
  }

  @override
  final ProjectDoc doc;

  @override
  Rt playhead = Rt.zero();

  bool playing = false;
  Timer? _playTimer;
  bool _frameBusy = false;
  double _shuttleRate = 1;

  final Map<String, PoolItem> pool = {};
  final Map<String, List<double>> waveforms = {};
  Uint8List? previewFrame;
  double previewFrameTime = -1;

  static const int previewWidth = 640;

  @override
  double get fps => doc.settings.fpsValue;

  double get shuttleRate => _shuttleRate;

  Rt get duration => doc.sequenceDuration;

  String get timecode => Rt.toTimecode(playhead, fps);
  String get durationTimecode => Rt.toTimecode(duration, fps);

  @override
  void dispose() {
    _playTimer?.cancel();
    _autosaveTimer?.cancel();
    super.dispose();
  }

  // --- Media pool -----------------------------------------------------------

  Future<void> importFiles(List<String> paths) async {
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
        doc.media.add(asset);
        pool[asset.id]!.status = ImportStatus.ready;
        unawaited(_loadThumbnailInto(pool[asset.id]!));
      } catch (e) {
        pool[asset.id]?.status = ImportStatus.failed;
        debugPrint('import failed for $path: $e');
      }
    }
    markDirty();
    notifyListeners();
  }

  Future<void> _warmThumbnails() async {
    for (final item in pool.values.toList()) {
      await _loadThumbnailInto(item);
    }
  }

  Future<void> _loadThumbnailInto(PoolItem item) async {
    if (item.thumb != null || item.asset.type == 'audio') return;
    final bytes = await loadThumbnail(item.asset);
    if (bytes == null) return;
    item.thumb = bytes;
    notifyListeners();
  }

  Future<Uint8List?> loadThumbnail(MediaAsset asset, {int width = 480}) async {
    try {
      return CrazyCutEngine.instance.extractThumbnail(
        asset.path,
        seconds: asset.duration.seconds > 2 ? 1.0 : 0.0,
        width: width,
      );
    } catch (e) {
      debugPrint('thumbnail failed: $e');
      return null;
    }
  }

  /// Peak envelope for an audio asset, cached per asset id. Returns an empty
  /// list while the engine is unavailable so the tile falls back to its
  /// synthetic bars.
  List<double> waveformFor(MediaAsset asset) {
    final cached = waveforms[asset.id];
    if (cached != null) return cached;
    waveforms[asset.id] = const [];
    unawaited(
      Future(() {
        try {
          final result = CrazyCutEngine.instance.extractWaveform(
            asset.path,
            peaksPerSecond: 20,
          );
          waveforms[asset.id] = result.peaks
              .map((p) => (p as num).toDouble().abs().clamp(0.0, 1.0))
              .toList(growable: false);
          notifyListeners();
        } catch (e) {
          debugPrint('waveform failed: $e');
        }
      }),
    );
    return const [];
  }

  /// Drops an asset onto the end of its natural track (video → V1, audio → A1).
  Future<void> appendClip(String assetId, {String? trackId, Rt? at}) async {
    final asset = doc.assetById(assetId);
    if (asset == null) return;
    final track = trackId != null
        ? trackById(trackId)
        : (asset.type == 'audio' ? doc.audioTrack() : doc.videoTrack());
    if (track == null) return;
    pushUndo();
    var start = at ?? Rt.zero();
    if (at == null) {
      for (final c in clipsOn(track.id)) {
        final end = c.start.plus(c.duration);
        if (end > start) start = end;
      }
    }
    final clip = Clip(
      id: generateId(),
      trackId: track.id,
      mediaId: assetId,
      label: asset.name,
      start: start,
      duration: asset.duration.isZero ? Rt.fromSeconds(5) : asset.duration,
      sourceIn: Rt.zero(),
    );
    doc.clips.add(clip);
    selectedClipId = clip.id;
    markDirty();
    notifyListeners();
  }

  // --- Playback / navigation ------------------------------------------------

  void seekTo(Rt t) {
    final clamped = t < Rt.zero() ? Rt.zero() : t;
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

  void goToStart() => seekTo(Rt.zero());
  void goToEnd() => seekTo(duration);

  void togglePlay() => playing ? stopPlayback() : play();

  /// J/L shuttle: repeated calls accelerate 1×→2×→4×→8× in the given
  /// direction, matching TIM-13.
  void shuttle({required bool forward}) {
    final sign = forward ? 1.0 : -1.0;
    if (playing && _shuttleRate.sign == sign) {
      _shuttleRate = (_shuttleRate.abs() * 2).clamp(1.0, 8.0) * sign;
    } else {
      _shuttleRate = sign;
    }
    play(rate: _shuttleRate);
  }

  void play({double rate = 1}) {
    _shuttleRate = rate;
    playing = true;
    final tickMs = (1000 / (fps <= 0 ? 30 : fps)).round().clamp(10, 250);
    _playTimer?.cancel();
    _playTimer = Timer.periodic(Duration(milliseconds: tickMs), (_) {
      final step = Rt.fromMicros((frameDuration.micros * _shuttleRate).round());
      final next = playhead.plus(step);
      if (next < Rt.zero()) {
        seekTo(Rt.zero());
        stopPlayback();
        return;
      }
      if (!duration.isZero && next > duration) {
        seekTo(duration);
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

  Clip? clipUnderPlayhead() {
    final video = doc.tracks.where((t) => t.kind == 'video').map((t) => t.id).toSet();
    return doc.clips.firstWhereOrNull(
      (c) =>
          video.contains(c.trackId) &&
          playhead >= c.start &&
          playhead < c.start.plus(c.duration),
    );
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
    if (asset == null) return;
    _frameBusy = true;
    try {
      final localSeconds = playhead.minus(clip.start).seconds;
      final sourceSeconds = clip.sourceIn.seconds + localSeconds;
      previewFrame = CrazyCutEngine.instance.extractThumbnail(
        asset.path,
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

  bool _dirty = false;
  Timer? _autosaveTimer;
  void Function()? onSaved;

  bool get isDirty => _dirty;

  @override
  void markDirty() {
    _dirty = true;
    // Mid-drag the document changes every frame; the engine only needs the
    // committed result, which endGesture() delivers.
    if (!inGesture) _syncEngineGraph();
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(seconds: 2), () async {
      if (!_dirty) return;
      await saveNow();
    });
  }

  void _syncEngineGraph() {
    try {
      CrazyCutEngine.instance.setProjectSnapshot(doc.encode());
    } catch (e) {
      debugPrint('engine graph sync failed: $e');
    }
  }

  Future<void> saveNow() async {
    await ProjectRepository.save(doc);
    _dirty = false;
    onSaved?.call();
  }
}
