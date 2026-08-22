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
import 'package:crazycut_app/state/audio_edits.dart';
import 'package:crazycut_app/state/preview_renderer.dart';
import 'package:crazycut_app/state/proxy_service.dart';
import 'package:crazycut_app/state/text_rasterizer.dart';
import 'package:crazycut_app/state/timeline_edits.dart';

enum ImportStatus { probing, ready, failed, offline }

class PoolItem {
  PoolItem({
    required this.asset,
    this.status = ImportStatus.probing,
    this.thumb,
  });
  final MediaAsset asset;
  ImportStatus status;
  Uint8List? thumb;
}

/// Files we accept (IMP: supported formats).
const kSupportedExtensions = {
  'mp4',
  'mov',
  'mkv',
  'webm',
  'm4v',
  'mp3',
  'm4a',
  'aac',
  'wav',
  'flac',
  'ogg',
  'png',
  'jpg',
  'jpeg',
  'webp',
  'gif',
};

/// Everything the editor screen reads and writes for one open project:
/// document edits (via [TimelineEdits]), the media pool, playback, the preview
/// frame, autosave and proxies.
class EditorController extends ChangeNotifier with TimelineEdits, AudioEdits {
  EditorController(this.doc, {required String path, ProxyService? proxies})
    : proxies = proxies ?? ProxyService() {
    autosave = ProjectAutosave(
      doc,
      path: path,
      onStateChanged: (_) => notifyListeners(),
    );
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
    unawaited(_bootRenderer());
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
  bool _framePending = false;
  int _previewRevision = 0;
  int _previewRenderMicros = 33333;
  double _shuttleRate = 1;

  /// Wall clock for playback. The playhead is derived from elapsed real time
  /// rather than accumulated timer ticks, so a slow frame makes playback drop
  /// frames instead of running in slow motion.
  final Stopwatch _playClock = Stopwatch();
  Rt _playAnchor = Rt.zero();

  PreviewRenderer? _renderer;
  Future<PreviewRenderer>? _rendererBoot;

  /// Realtime monitoring of the sequence mix (M3). Null when the engine is
  /// unavailable; playback then falls back to the wall clock alone.
  SequenceAudioPlayer? _audio;
  bool _audioDocDirty = true;

  /// Master output meter, updated while playing (AUD-10).
  (double, double) audioLevels = (0, 0);

  /// Output device chosen in settings; empty means system default (AUD-14).
  String outputDeviceName = '';

  final Map<String, PoolItem> pool = {};
  Uint8List? previewFrame;
  (int, int)? previewFrameSize;
  double previewFrameTime = -1;

  /// Effect catalog from the engine (cc_effect_catalog), lazily fetched once
  /// per session; falls back to the bundled catalog when the engine is
  /// unavailable so the inspector always renders.
  List<Map<String, dynamic>>? _catalogCache;
  Future<List<Map<String, dynamic>>> effectCatalogOrFallback() async {
    if (_catalogCache != null) return _catalogCache!;
    try {
      _catalogCache = CrazyCutEngine.instance.effectCatalog();
    } catch (e) {
      debugPrint('effect catalog unavailable: $e');
      _catalogCache = TimelineEdits.kFallbackEffectCatalog;
    }
    return _catalogCache!;
  }

  /// Synchronous view of the last-fetched (or fallback) catalog for widgets
  /// that only need labels/ranges.
  List<Map<String, dynamic>> get catalogCache =>
      _catalogCache ?? TimelineEdits.kFallbackEffectCatalog;

  /// Names skipped on the last import (IMP-4).
  List<String> lastSkipped = const [];

  /// Floor for the preview render size; the monitor asks for more when it is
  /// displayed larger (see [setPreviewWidth]).
  static const int minPreviewWidth = 640;

  /// Never render preview above this, whatever the display size: past ~1080p
  /// wide the cost outruns what the monitor can show.
  static const int maxPreviewWidth = 1920;

  /// Full-resolution frames are restored whenever playback stops. While the
  /// transport is moving, cap the render size so decoding/compositing stays
  /// ahead of a 30 fps playhead on high-DPI displays.
  static const int maxPlaybackPreviewWidth = 960;

  int _previewWidth = minPreviewWidth;
  int get previewWidth => _previewWidth;

  /// The monitor reports the pixel width it actually paints into; rendering at
  /// that size instead of a fixed 640 is what makes the preview sharp. Values
  /// are quantised so a resize drag does not re-render on every pixel.
  void setPreviewWidth(int pixels) {
    // Rendering above the sequence resolution only costs time: the compositor
    // would be upscaling every source past what the project will ever output.
    final ceiling = doc.settings.width.clamp(minPreviewWidth, maxPreviewWidth);
    final capped = pixels.clamp(minPreviewWidth, ceiling);
    final quantised = ((capped / 160).ceil() * 160).clamp(
      minPreviewWidth,
      ceiling,
    );
    if (quantised == _previewWidth) return;
    _previewWidth = quantised;
    _previewRevision++;
    unawaited(updatePreviewFrame());
  }

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

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _playTimer?.cancel();
    _liveEditTimer?.cancel();
    _audio?.stop();
    _audio?.dispose();
    _audio = null;
    unawaited(_renderer?.dispose());
    _renderer = null;
    proxies.removeListener(notifyListeners);
    proxies.dispose();
    autosave.dispose();
    super.dispose();
  }

  Future<void> close() async {
    _disposed = true;
    _playTimer?.cancel();
    playing = false;
    _audio?.stop();
    _audio?.dispose();
    _audio = null;
    await _renderer?.dispose();
    _renderer = null;
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

  Future<void> importFiles(
    List<String> paths, {
    bool addToTimeline = true,
  }) async {
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
        final duplicate = doc.media.firstWhereOrNull(
          (item) => item.hash == hash,
        );
        if (duplicate != null) {
          // IMP-3: re-importing the same content selects the existing asset.
          pool.remove(asset.id);
          pool[duplicate.id] = PoolItem(
            asset: duplicate,
            status: ImportStatus.ready,
          );
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
    deleteClips(
      doc.clips.where((c) => c.mediaId == assetId).map((c) => c.id).toList(),
    );
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
    pool[assetId]?.status =
        asset.offline ? ImportStatus.offline : ImportStatus.ready;
    if (!asset.offline) {
      proxies.request(asset);
      unawaited(_loadThumbnailInto(pool[assetId]!));
    }
    markDirty();
    notifyListeners();
  }

  List<MediaAsset> get offlineAssets =>
      doc.media.where((a) => a.offline).toList();

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
    if (item.thumb != null || item.asset.type == 'audio' || item.asset.offline) {
      return;
    }
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
  Uint8List? filmstripTile(
    MediaAsset asset,
    double sourceSeconds, {
    int width = 160,
  }) {
    if (asset.offline) return null;
    final quantised = (sourceSeconds * 2).floor() / 2;
    final cached = MediaCache.instance.thumbNow(asset, quantised, width: width);
    if (cached != null) return cached;
    unawaited(
      MediaCache.instance.thumb(
        asset,
        quantised,
        width: width,
        onReady: notifyListeners,
      ),
    );
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
    if (playing) _anchorPlayClock();
    notifyListeners();
    unawaited(updatePreviewFrame());
  }

  /// Restarts the wall clock from the current playhead.
  void _anchorPlayClock() {
    _playAnchor = playhead;
    _playClock
      ..reset()
      ..start();
    if (playing) _audio?.seek(playhead.seconds);
  }

  /// Audio device, project snapshot and levels for monitoring.
  SequenceAudioPlayer? _ensureAudio() {
    if (_audio != null) return _audio;
    try {
      _audio = CrazyCutEngine.instance.createSequencePlayer();
      if (outputDeviceName.isNotEmpty) {
        _audio!.outputDevice = outputDeviceName;
      }
    } catch (e) {
      debugPrint('audio monitoring unavailable: $e');
      return null;
    }
    return _audio;
  }

  void _pushAudioDocument() {
    final audio = _audio;
    if (audio == null || !_audioDocDirty) return;
    final paths = <String, String>{};
    for (final asset in doc.media) {
      if (asset.offline) continue;
      paths[asset.id] = asset.path; // originals: proxies drop audio quality
    }
    audio.setDocument(doc.encode(touchModified: false), paths);
    _audioDocDirty = false;
  }

  /// Last "Analyze sequence loudness" result (AUD-12), null until measured.
  LoudnessReport? loudness;
  bool analyzingLoudness = false;

  /// Measures integrated loudness of the sequence (or the in/out range).
  Future<LoudnessReport?> analyzeLoudness() async {
    if (analyzingLoudness) return loudness;
    final from = rangeStart;
    final to = rangeEnd;
    final seconds = to.seconds - from.seconds;
    if (seconds <= 0) return null;
    analyzingLoudness = true;
    notifyListeners();
    try {
      final paths = <String, String>{};
      for (final asset in doc.media) {
        if (asset.offline) continue;
        paths[asset.id] = asset.path;
      }
      // Analysis reads the same mix the export writes, so the number the
      // dialog shows is the number the file will measure.
      loudness = CrazyCutEngine.instance.analyzeLoudness(
        startSec: from.seconds,
        seconds: seconds,
        mediaPaths: paths,
      );
      return loudness;
    } catch (e) {
      debugPrint('loudness analysis failed: $e');
      return null;
    } finally {
      analyzingLoudness = false;
      notifyListeners();
    }
  }

  /// Peak-scans a clip and applies the gain that lands it at −1 dBFS (AUD-5).
  Future<void> normalizeClip(String clipId) async {
    final clip = clipById(clipId);
    if (clip == null) return;
    final asset = doc.assetById(clip.mediaId);
    if (asset == null || asset.offline || !asset.hasAudio) return;
    try {
      final peak = CrazyCutEngine.instance.scanAudioPeak(
        asset.path,
        sourceInSec: clip.sourceIn.seconds,
        seconds: clip.duration.seconds * clip.speedValue,
      );
      applyNormalizedGain(clipId, peak);
    } catch (e) {
      debugPrint('normalize failed: $e');
    }
  }

  /// Output devices offered in settings (AUD-14).
  List<String> audioOutputDevices() {
    try {
      return CrazyCutEngine.instance.audioOutputDevices();
    } catch (_) {
      return const [];
    }
  }

  void setOutputDevice(String name) {
    if (name == outputDeviceName) return;
    outputDeviceName = name;
    _audio?.outputDevice = name;
    if (playing) {
      _audio?.stop();
      _audio?.start(playhead.seconds);
    }
    notifyListeners();
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
    if (playhead >= rangeEnd && rate > 0) playhead = rangeStart;
    final audio = _ensureAudio();
    if (audio != null) {
      _pushAudioDocument();
      audio.rate = rate;
      audio.start(playhead.seconds);
    }
    _anchorPlayClock();
    // Tick faster than the frame rate so the playhead lands on the right frame
    // even when a tick is slightly late; the clock, not the tick count, decides
    // where the playhead is.
    final tickMs = (500 / (fps <= 0 ? 30 : fps)).round().clamp(8, 125);
    _playTimer?.cancel();
    _playTimer = Timer.periodic(Duration(milliseconds: tickMs), (_) => _tick());
    notifyListeners();
    unawaited(updatePreviewFrame());
  }

  /// Advances the playhead to wherever the wall clock says it should be. If
  /// rendering cannot keep up the preview drops frames — playback stays in
  /// real time, which is what an editor needs to judge timing.
  void _tick() {
    // The audio device's sample count is the master clock when monitoring is
    // live (arch §6); it cannot drift against what the user hears. The wall
    // clock covers silent projects and machines with no output device.
    final audio = _audio;
    var next = _playAnchor.plus(
      Rt.fromMicros((_playClock.elapsedMicroseconds * _shuttleRate).round()),
    );
    if (audio != null && audio.running && _shuttleRate > 0) {
      final fromAudio = Rt.fromSeconds(audio.position);
      // Ignore an audio clock that has run away (device glitch, resync).
      if ((fromAudio.seconds - next.seconds).abs() < 0.5) next = fromAudio;
      audioLevels = audio.levels;
    }
    final end = rangeEnd;

    if (_shuttleRate < 0 && next < rangeStart) {
      if (looping) {
        playhead = end.isZero ? rangeStart : end;
        _anchorPlayClock();
        notifyListeners();
        unawaited(updatePreviewFrame());
        return;
      }
      playhead = rangeStart;
      notifyListeners();
      unawaited(updatePreviewFrame());
      stopPlayback();
      return;
    }
    if (_shuttleRate > 0 && !end.isZero && next > end) {
      if (looping) {
        playhead = rangeStart;
        _anchorPlayClock();
        notifyListeners();
        unawaited(updatePreviewFrame());
        return;
      }
      playhead = end;
      notifyListeners();
      unawaited(updatePreviewFrame());
      stopPlayback();
      return;
    }

    // Snap to the frame grid so the preview and timecode agree.
    final frameMicros = frameDuration.micros;
    if (frameMicros > 0) {
      final frames = next.micros ~/ frameMicros;
      next = Rt.fromMicros(frames * frameMicros);
    }
    if (next == playhead) return;
    playhead = next;
    notifyListeners();
    unawaited(updatePreviewFrame());
  }

  void stopPlayback() {
    _playTimer?.cancel();
    _playTimer = null;
    _playClock.stop();
    _audio?.stop();
    _audio?.rate = 1;
    audioLevels = (0, 0);
    playing = false;
    _shuttleRate = 1;
    notifyListeners();
    // Replace the responsive playback frame with the sharp parked frame.
    unawaited(updatePreviewFrame());
  }

  void toggleLoop() {
    looping = !looping;
    notifyListeners();
  }

  /// Text clip under the playhead on a visible video track, topmost first
  /// (TXT-6 inline editing target).
  Clip? textClipUnderPlayhead() {
    final tracks = doc.videoTracks.where((t) => !t.hidden).toList().reversed;
    for (final track in tracks) {
      final hit = doc
          .clipsOn(track.id)
          .firstWhereOrNull(
            (c) => c.text != null && playhead >= c.start && playhead < c.end,
          );
      if (hit != null) return hit;
    }
    return null;
  }

  /// Topmost visible video clip under the playhead.
  Clip? clipUnderPlayhead() {
    final tracks = doc.videoTracks.where((t) => !t.hidden).toList().reversed;
    for (final track in tracks) {
      final hit = doc
          .clipsOn(track.id)
          .firstWhereOrNull((c) => playhead >= c.start && playhead < c.end);
      if (hit != null) return hit;
    }
    return null;
  }

  /// Clip the on-canvas transform gizmo should target: the selection when it
  /// is a rasterised visual clip under the playhead, otherwise the topmost one.
  ///
  /// Text clips are excluded — their texture is a Dart-side raster whose size
  /// is unrelated to any media asset, so the gizmo cannot derive their rect.
  Clip? gizmoClipUnderPlayhead() {
    bool eligible(Clip c) {
      if (c.text != null || c.mediaId.isEmpty) return false;
      if (!(playhead >= c.start && playhead < c.end)) return false;
      final track = doc.trackById(c.trackId);
      if (track == null || !track.isVideo || track.hidden || track.lock) {
        return false;
      }
      return gizmoSourceSize(c) != null;
    }

    for (final id in selection) {
      final clip = doc.clipById(id);
      if (clip != null && eligible(clip)) return clip;
    }
    // A selected text/audio/off-playhead clip is still an intentional target.
    // Do not draw handles for an unrelated image underneath it; that made the
    // text editor look as if it were manipulating the wrong object.
    if (selection.isNotEmpty) return null;
    final tracks = doc.videoTracks.where((t) => !t.hidden).toList().reversed;
    for (final track in tracks) {
      final hit = doc.clipsOn(track.id).firstWhereOrNull(eligible);
      if (hit != null) return hit;
    }
    return null;
  }

  /// Natural pixel size of a clip's source, or null when the asset never got
  /// probed (an offline or audio asset) and the gizmo has nothing to measure.
  (int, int)? gizmoSourceSize(Clip clip) {
    final asset = doc.assetById(clip.mediaId);
    if (asset == null || asset.type == 'audio') return null;
    final w = asset.width ?? 0;
    final h = asset.height ?? 0;
    return w > 0 && h > 0 ? (w, h) : null;
  }

  /// Boots the render isolate and paints the first frame.
  Future<PreviewRenderer> _bootRenderer() async {
    final existing = _rendererBoot;
    if (existing != null) return existing;
    final boot = PreviewRenderer.spawn();
    _rendererBoot = boot;
    final renderer = await boot;
    if (_disposed) {
      await renderer.dispose();
      return renderer;
    }
    _renderer = renderer;
    renderer.setSnapshot(doc.encode(touchModified: false));
    unawaited(updatePreviewFrame());
    return renderer;
  }

  /// Composited preview: the engine renders every visible video track at the
  /// playhead through the same path export uses (arch §1). Text clips are
  /// rasterized here (Flutter) and pushed in as textures so on-canvas text is
  /// WYSIWYG with the inline editor.
  ///
  /// The composite itself runs on [PreviewRenderer]'s isolate; this method only
  /// gathers inputs and publishes the result.
  Future<void> updatePreviewFrame() async {
    // A render is in flight; remember that the playhead moved so the newest
    // position still gets drawn instead of being silently dropped.
    if (_frameBusy) {
      _framePending = true;
      return;
    }
    final renderer = _renderer;
    if (renderer == null) {
      unawaited(_bootRenderer());
      return;
    }
    _frameBusy = true;
    try {
      final revision = _previewRevision;
      final playbackRequest = playing;
      // Render the time at which this frame is expected to reach the screen,
      // not the time at which expensive decoding began. The moving average
      // self-corrects for effects/layer complexity and keeps visual cuts in
      // step with the realtime playhead.
      final requested = computePreviewRenderTime(
        playhead: playhead,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        frameDuration: frameDuration,
        playing: playbackRequest,
        rate: _shuttleRate,
        renderMicros: _previewRenderMicros,
      );
      final activeMedia = <String>{};
      for (final clip in doc.clips) {
        final track = doc.trackById(clip.trackId);
        if (track == null || !track.isVideo || track.hidden) continue;
        if (requested >= clip.start &&
            requested < clip.end &&
            clip.mediaId.isNotEmpty) {
          activeMedia.add(clip.mediaId);
        }
      }
      final mediaPaths = <String, String>{};
      for (final asset in doc.media) {
        if (!activeMedia.contains(asset.id) ||
            asset.offline ||
            asset.type == 'audio') {
          continue;
        }
        mediaPaths[asset.id] = ProxyService.decodePath(asset);
      }
      final width =
          playing && _previewWidth > maxPlaybackPreviewWidth
              ? maxPlaybackPreviewWidth
              : _previewWidth;
      var height = (width * doc.settings.height / doc.settings.width).round();
      if (height.isOdd) height += 1;
      final textures = <String, Uint8List>{};
      final textureSizes = <String, (int, int)>{};
      for (final clip in doc.clips) {
        if (clip.text == null) continue;
        final track = doc.trackById(clip.trackId);
        if (track == null || !track.isVideo || track.hidden) continue;
        if (!(requested >= clip.start && requested < clip.end)) continue;
        final raster = await TextRasterizer.instance.render(
          clip.text!,
          canvasWidth: width,
          sequenceHeight: height,
          localSeconds: (requested - clip.start).seconds,
        );
        if (raster == null) continue;
        textures['text:${clip.id}'] = raster.bytes;
        textureSizes['text:${clip.id}'] = (raster.width, raster.height);
      }

      final renderWatch = Stopwatch()..start();
      final frame = await renderer.render(
        time: requested,
        width: width,
        height: height,
        mediaPaths: mediaPaths,
        textures: textures,
        textureSizes: textureSizes,
      );
      renderWatch.stop();
      if (playbackRequest) {
        _previewRenderMicros =
            (_previewRenderMicros * 0.75 +
                    renderWatch.elapsedMicroseconds * 0.25)
                .round();
      }
      if (_disposed) return;
      final current = isPreviewFrameCurrent(
        requestRevision: revision,
        currentRevision: _previewRevision,
        requestWasPlaying: playbackRequest,
        currentlyPlaying: playing,
        requested: requested,
        playhead: playhead,
        frameDuration: frameDuration,
      );
      if (current) {
        previewFrame = frame.rgba;
        previewFrameSize = (frame.width, frame.height);
        previewFrameTime = frame.time.seconds;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('preview frame failed: $e');
    } finally {
      _frameBusy = false;
    }
    if (_framePending && !_disposed) {
      _framePending = false;
      await updatePreviewFrame();
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

  Timer? _liveEditTimer;
  DateTime _lastLiveEdit = DateTime.fromMillisecondsSinceEpoch(0);
  static const _liveEditInterval = Duration(milliseconds: 40);

  /// Refreshes the monitor from an *uncommitted* gesture.
  ///
  /// [markDirty] deliberately withholds the snapshot until a gesture commits,
  /// which is right for a timeline drag: the document churns every frame and
  /// only the committed result matters. Direct manipulation on the monitor is
  /// the exception — watching the image follow the pointer is the whole point
  /// of it — so this pushes the in-progress document to the preview renderer,
  /// and to nothing else: no history, no autosave, no audio graph.
  void previewLiveEdit() {
    if (!inGesture || _disposed) return;
    final since = DateTime.now().difference(_lastLiveEdit);
    if (since >= _liveEditInterval) {
      _pushLivePreview();
      return;
    }
    // Trailing edge: the last move of a drag must not be the one throttling
    // drops, or the frame sits stale until the pointer comes up.
    _liveEditTimer?.cancel();
    _liveEditTimer = Timer(_liveEditInterval - since, _pushLivePreview);
  }

  void _pushLivePreview() {
    _liveEditTimer?.cancel();
    _liveEditTimer = null;
    if (_disposed) return;
    _lastLiveEdit = DateTime.now();
    // Only the render isolate: the in-process engine serves audio and
    // thumbnails, which an in-flight drag has nothing to say to.
    _previewRevision++;
    _renderer?.setSnapshot(doc.encode(touchModified: false));
    unawaited(updatePreviewFrame());
  }

  void _syncEngineGraph() {
    _previewRevision++;
    final snapshot = doc.encode(touchModified: false);
    try {
      CrazyCutEngine.instance.setProjectSnapshot(snapshot);
    } catch (e) {
      debugPrint('engine graph sync failed: $e');
    }
    // The render isolate holds its own engine, so it needs the same document.
    _renderer?.setSnapshot(snapshot);
    _audioDocDirty = true;
    if (playing) _pushAudioDocument();
    // A committed edit, undo or redo can change the frame under a stationary
    // playhead. Snapshotting alone leaves the old pixels on screen.
    unawaited(updatePreviewFrame());
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
