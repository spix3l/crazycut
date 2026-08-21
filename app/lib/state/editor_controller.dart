import 'dart:async';
import 'dart:io';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:flutter/foundation.dart';

enum ImportStatus { probing, ready, failed }

class PoolItem {
  PoolItem({required this.asset, this.status = ImportStatus.probing});
  final MediaAsset asset;
  ImportStatus status;
}

class EditorController extends ChangeNotifier {
  EditorController(this.doc);

  final ProjectDoc doc;

  Rt playhead = Rt.zero();
  String? selectedClipId;
  bool playing = false;
  Timer? _playTimer;
  bool _frameBusy = false;

  final Map<String, PoolItem> pool = {};
  Uint8List? previewFrame;
  double previewFrameTime = -1;

  static const int previewWidth = 640;

  double get fps => doc.settings.fpsValue;

  @override
  void dispose() {
    _playTimer?.cancel();
    super.dispose();
  }

  void selectClip(String id) {
    selectedClipId = id;
    notifyListeners();
  }

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
        pool[asset.id]!.status = ImportStatus.ready;
        await appendClip(asset.id);
      } catch (e) {
        debugPrint('import failed for $path: $e');
      }
    }
    markDirty();
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

  Future<void> appendClip(String assetId) async {
    final track = doc.videoTrack();
    final asset = doc.assetById(assetId);
    if (track == null || asset == null) return;
    var start = Rt.zero();
    for (final c in doc.clips) {
      if (c.trackId == track.id) {
        final end = c.start.plus(c.duration);
        if (end > start) start = end;
      }
    }
    doc.clips.add(Clip(
      id: generateId(),
      trackId: track.id,
      mediaId: assetId,
      label: asset.name,
      start: start,
      duration: asset.duration,
      sourceIn: Rt.zero(),
    ));
    markDirty();
    notifyListeners();
  }

  void seekTo(Rt t) {
    playhead = t < Rt.zero() ? Rt.zero() : t;
    notifyListeners();
  }

  void togglePlay() {
    if (playing) {
      stopPlayback();
    } else {
      playing = true;
      final frameDurMs =
          (1000 / (fps <= 0 ? 30 : fps)).round().clamp(10, 250);
      _playTimer?.cancel();
      _playTimer = Timer.periodic(Duration(milliseconds: frameDurMs), (_) {
        if (_frameBusy) return;
        final next = playhead.plus(
            Rt.fromMicros((1000000 / (fps <= 0 ? 30 : fps)).round()));
        if (doc.sequenceDuration != Rt.zero() && next > doc.sequenceDuration) {
          stopPlayback();
          return;
        }
        seekTo(next);
      });
      notifyListeners();
    }
  }

  void stopPlayback() {
    _playTimer?.cancel();
    playing = false;
    notifyListeners();
  }

  Clip? clipUnderPlayhead() {
    for (final c in doc.clips) {
      final end = c.start.plus(c.duration);
      if (playhead >= c.start && playhead < end && c.trackId == doc.videoTrack()?.id) {
        return c;
      }
    }
    return null;
  }

  Future<void> updatePreviewFrame() async {
    final clip = clipUnderPlayhead();
    if (clip == null || _frameBusy) return;
    final asset = doc.assetById(clip.mediaId);
    if (asset == null) return;
    _frameBusy = true;
    try {
      final localSeconds = playhead.minus(clip.start).seconds;
      final sourceSeconds = clip.sourceIn.seconds + localSeconds;
      final bytes = CrazyCutEngine.instance
          .extractThumbnail(asset.path, seconds: sourceSeconds, width: previewWidth);
      previewFrame = bytes;
      previewFrameTime = playhead.seconds;
      notifyListeners();
    } catch (e) {
      debugPrint('preview frame failed: $e');
    } finally {
      _frameBusy = false;
    }
  }

  bool _dirty = false;
  Timer? _autosaveTimer;
  Function? onSaved;

  void markDirty() {
    _dirty = true;
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(seconds: 2), () async {
      if (!_dirty) return;
      await ProjectRepository.save(doc);
      _dirty = false;
      onSaved?.call();
    });
  }

  Future<void> saveNow() async {
    await ProjectRepository.save(doc);
    _dirty = false;
    onSaved?.call();
  }
}
