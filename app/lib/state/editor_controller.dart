import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset, Rect;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'package:crazycut_app/data/autosave.dart';
import 'package:crazycut_app/data/media_cache.dart';
import 'package:crazycut_app/data/param_value.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/audio_edits.dart';
import 'package:crazycut_app/state/canvas_geometry.dart';
import 'package:crazycut_app/state/preview_renderer.dart';
import 'package:crazycut_app/state/proxy_service.dart';
import 'package:crazycut_app/state/svg_rasterizer.dart';
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
  'svg',
};

/// Everything the editor screen reads and writes for one open project:
/// document edits (via [TimelineEdits]), the media pool, playback, the preview
/// frame, autosave and proxies.
class EditorController extends ChangeNotifier with TimelineEdits, AudioEdits {
  EditorController(this.doc, {required String path, ProxyService? proxies})
    : proxies = proxies ?? ProxyService(),
      _ownsProxies = proxies == null {
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
    unawaited(_prepareMedia());
    unawaited(_bootRenderer());
  }

  @override
  final ProjectDoc doc;

  late final ProjectAutosave autosave;
  final ProxyService proxies;

  /// A controller-created proxy queue follows the controller lifetime. The
  /// app session injects its shared queue so jobs can survive project changes;
  /// that queue must only be detached here, never disposed here.
  final bool _ownsProxies;

  /// Playhead position.
  ///
  /// Assignment publishes on [playheadNotifier] rather than through
  /// [notifyListeners]: the transport moves the playhead 30-60 times a second
  /// and only a handful of widgets (the ruler head, the timeline cursor, the
  /// timecode) need to follow it at that rate. Rebuilding the whole editor —
  /// media pool, inspector, every timeline clip — on each step is what made
  /// playback feel heavy.
  @override
  Rt get playhead => playheadNotifier.value;
  set playhead(Rt value) => playheadNotifier.value = value;

  /// Transport-rate playhead channel (see [playhead]).
  final ValueNotifier<Rt> playheadNotifier = ValueNotifier(Rt.zero());

  /// Transport-rate preview image channel. Only the monitor listens, so a new
  /// frame repaints one widget instead of the whole editor.
  final ValueNotifier<PreviewFrame?> previewImage = ValueNotifier(null);
  final Map<String, (int, int)> _textGizmoSizes = {};

  bool playing = false;
  bool looping = false;
  Timer? _playTimer;
  int _framesInFlight = 0;
  bool _framePending = false;
  int _previewRevision = 0;
  int _previewRenderMicros = 33333;
  double _shuttleRate = 1;

  /// How many composites may be outstanding at once.
  ///
  /// With a single slot the render isolate sits idle for the whole round trip
  /// — completion hop, image decode, repaint — before the next frame is even
  /// dispatched, so preview throughput was bounded by *latency* rather than by
  /// compositing cost. A second slot lets the isolate composite frame N+1
  /// while the UI thread is still putting frame N on screen. Deeper than two
  /// only buys latency: frames would queue behind a playhead that has already
  /// moved past them.
  static const int _maxFramesInFlight = 2;

  /// Identity of the frame currently on the monitor: (revision, requested
  /// micros, render width). A request with this key would composite the image
  /// that is already on screen, so it is skipped rather than given a slot the
  /// newest playhead position could have used. Keyed on what was *shown*, not
  /// on what was last dispatched — a request that never reached the monitor
  /// must stay repeatable.
  (int, int, int)? _shownKey;

  /// Dispatch order. Stamped when a request starts and compared against
  /// [_shownSeq] before publishing, so an older request cannot overwrite a
  /// newer one that overtook it.
  int _requestSeq = 0;
  int _shownSeq = 0;

  bool get _frameBusy => _framesInFlight >= _maxFramesInFlight;

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
  ///
  /// On its own channel for the same reason as [playhead]: meter ballistics
  /// need every tick, and the rest of the editor does not.
  final ValueNotifier<(double, double)> audioLevelsNotifier =
      ValueNotifier((0, 0));
  (double, double) get audioLevels => audioLevelsNotifier.value;
  set audioLevels((double, double) value) =>
      audioLevelsNotifier.value = value;

  /// Output device chosen in settings; empty means system default (AUD-14).
  String outputDeviceName = '';

  final Map<String, PoolItem> pool = {};

  /// Last composited frame, as views onto [previewImage] for callers that only
  /// read it occasionally (the monitor itself listens to the notifier).
  Uint8List? get previewFrame => previewImage.value?.rgba;
  (int, int)? get previewFrameSize {
    final frame = previewImage.value;
    return frame == null ? null : (frame.width, frame.height);
  }

  double get previewFrameTime => previewImage.value?.time.seconds ?? -1;

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

  /// Cap while a direct-manipulation gesture is open. A full-resolution
  /// composite of a real project measures 30-110 ms; at that latency the image
  /// visibly trails the handles the pointer is dragging, which reads as the
  /// gizmo sitting off its own clip. The committed edit re-renders at full size
  /// the moment the gesture ends, so the softness is only ever on screen while
  /// the mouse button is down.
  static const int maxLiveEditPreviewWidth = 640;

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
    _notifyTrailing?.cancel();
    _audio?.stop();
    _audio?.dispose();
    _audio = null;
    unawaited(_renderer?.dispose());
    _renderer = null;
    playheadNotifier.dispose();
    previewImage.dispose();
    audioLevelsNotifier.dispose();
    proxies.removeListener(notifyListeners);
    if (_ownsProxies) proxies.dispose();
    autosave.dispose();
    super.dispose();
  }

  Future<void> close() async {
    _disposed = true;
    _playTimer?.cancel();
    _notifyTrailing?.cancel();
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
      final svg = isSvgPath(path);
      final asset = MediaAsset(
        id: generateId(),
        name: name,
        path: path,
        type: svg ? 'image' : 'video',
        duration: Rt.zero(),
        hasAudio: !svg,
      );
      pool[asset.id] = PoolItem(asset: asset);
      notifyListeners();
      try {
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
        Uint8List? svgThumb;
        if (svg) {
          final raster = await SvgRasterizer.instance.rasterize(
            asset,
            canvasWidth: doc.settings.width,
            canvasHeight: doc.settings.height,
          );
          asset
            ..width = raster.width
            ..height = raster.height
            ..codec = 'svg';
          svgThumb = raster.png;
        } else {
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
        }
        asset.thumbStatus = ThumbStatus.pending;
        doc.media.add(asset);
        pool[asset.id]!
          ..status = ImportStatus.ready
          ..thumb = svgThumb;
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
      if (isSvgPath(newPath)) {
        asset.extra.remove('svgRasterPath');
        try {
          final raster = await SvgRasterizer.instance.rasterize(
            asset,
            canvasWidth: doc.settings.width,
            canvasHeight: doc.settings.height,
          );
          asset
            ..type = 'image'
            ..hasAudio = false
            ..width = raster.width
            ..height = raster.height
            ..codec = 'svg';
          pool[assetId]?.thumb = raster.png;
        } on Object catch (e) {
          debugPrint('SVG relink rasterization failed: $e');
        }
      }
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

  Future<void> _prepareMedia() async {
    for (final item in pool.values.toList()) {
      if (isSvgPath(item.asset.path) && !item.asset.offline) {
        try {
          final raster = await SvgRasterizer.instance.rasterize(
            item.asset,
            canvasWidth: doc.settings.width,
            canvasHeight: doc.settings.height,
          );
          item
            ..thumb = raster.png
            ..status = ImportStatus.ready;
          item.asset
            ..type = 'image'
            ..hasAudio = false
            ..width = raster.width
            ..height = raster.height
            ..codec = 'svg';
        } on Object catch (e) {
          item.status = ImportStatus.failed;
          debugPrint('SVG preparation failed: $e');
        }
      }
      await _loadThumbnailInto(item);
    }
    notifyListeners();
    unawaited(updatePreviewFrame());
  }

  Future<void> _loadThumbnailInto(PoolItem item) async {
    if (item.thumb != null ||
        item.asset.type == 'audio' ||
        item.asset.offline) {
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
    // The cursor, the timecode and the monitor follow on their own channels;
    // a scrub drag emits seeks faster than the rest of the editor needs to be
    // rebuilt, so those go out on the throttle.
    playhead = clamped;
    if (playing) _anchorPlayClock();
    _notifyPlayback();
    unawaited(updatePreviewFrame());
  }

  static const Duration _playbackNotifyInterval = Duration(milliseconds: 100);
  final Stopwatch _sinceNotify = Stopwatch()..start();
  Timer? _notifyTrailing;

  /// Coarse editor refresh while the playhead is moving.
  ///
  /// The playhead, the preview image and the meters reach the screen through
  /// their own notifiers at full rate. Everything else that reads the playhead
  /// — inspector values, the clip-under-playhead highlight — only has to look
  /// current, so it rebuilds on a slow cadence instead of once per composited
  /// frame.
  ///
  /// Leading edge plus a guaranteed trailing edge: an isolated seek refreshes
  /// the editor at once, and the last position of a burst always lands even if
  /// it arrived inside the quiet window.
  void _notifyPlayback() {
    final waited = _sinceNotify.elapsed;
    if (waited >= _playbackNotifyInterval) {
      _notifyTrailing?.cancel();
      _notifyTrailing = null;
      _sinceNotify.reset();
      notifyListeners();
      return;
    }
    _notifyTrailing ??= Timer(_playbackNotifyInterval - waited, () {
      _notifyTrailing = null;
      _sinceNotify.reset();
      if (!_disposed) notifyListeners();
    });
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
    // Publishes on playheadNotifier: the cursor and the timecode follow every
    // step, the rest of the editor refreshes on the slow cadence below.
    playhead = next;
    _notifyPlayback();
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
  Clip? gizmoClipUnderPlayhead() {
    for (final id in selection) {
      final clip = doc.clipById(id);
      if (clip != null && _gizmoEligible(clip)) return clip;
    }
    // A selected text/audio/off-playhead clip is still an intentional target.
    // Do not draw handles for an unrelated image underneath it; that made the
    // text editor look as if it were manipulating the wrong object.
    if (selection.isNotEmpty) return null;
    return gizmoClipsUnderPlayhead().firstOrNull;
  }

  /// Every clip the gizmo could target, front-most first — what a click on the
  /// monitor has to choose between when images overlap. Without this, clicking
  /// one image dragged whichever clip happened to be selected instead.
  List<Clip> gizmoClipsUnderPlayhead() {
    final out = <Clip>[];
    for (final track
        in doc.videoTracks.where((t) => !t.hidden).toList().reversed) {
      out.addAll(doc.clipsOn(track.id).where(_gizmoEligible));
    }
    return out;
  }

  bool _gizmoEligible(Clip c) {
    if (c.text == null && c.mediaId.isEmpty) return false;
    if (!(playhead >= c.start && playhead < c.end)) return false;
    final track = doc.trackById(c.trackId);
    if (track == null || !track.isVideo || track.hidden || track.lock) {
      return false;
    }
    return gizmoSourceSize(c) != null;
  }

  /// Natural pixel size of a clip's source, or null when the asset/text raster
  /// has not been measured yet and the gizmo has nothing truthful to outline.
  (int, int)? gizmoSourceSize(Clip clip) {
    if (clip.text case final text?) {
      return _textGizmoSizes[clip.id] ??
          TextRasterizer.instance.measure(
            text,
            canvasWidth: doc.settings.width,
            sequenceHeight: doc.settings.height,
            localSeconds: clipLocalTime(clip).seconds,
          );
    }
    final asset = doc.assetById(clip.mediaId);
    if (asset == null || asset.type == 'audio') return null;
    final w = asset.width ?? 0;
    final h = asset.height ?? 0;
    return w > 0 && h > 0 ? (w, h) : null;
  }

  // --- Canvas geometry (shared by the gizmo and the align ops) --------------

  /// Clip-local time canvas edits read and write at — the same value the
  /// inspector's transform rows pass to [setTransformParam].
  Rt clipLocalTime(Clip clip) =>
      playhead.minus(clip.start).clampTo(Rt.zero(), clip.duration);

  /// Evaluates an animatable transform param at the clip-local playhead.
  double evalTransformNum(ParamValue param, Clip clip, double fallback) {
    final v = param.evaluate(clipLocalTime(clip));
    return v is num ? v.toDouble() : fallback;
  }

  /// The clip's unrotated rect in sequence pixels at the current playhead, or
  /// null when the source was never probed.
  Rect? clipRectInSequence(Clip clip) {
    final size = gizmoSourceSize(clip);
    if (size == null) return null;
    final t = clip.transformOrDefault;
    final anchor = t.anchor.evaluate(clipLocalTime(clip));
    double axis(String key) =>
        anchor is Map && anchor[key] is num
            ? (anchor[key] as num).toDouble()
            : 0;
    return layerRectInSequence(
      seqW: doc.settings.width,
      seqH: doc.settings.height,
      srcW: size.$1,
      srcH: size.$2,
      framing: clip.text != null ? 'native' : t.framing,
      x: evalTransformNum(t.x, clip, 0),
      y: evalTransformNum(t.y, clip, 0),
      scalePercent: evalTransformNum(t.scale, clip, 100),
      anchorX: axis('x'),
      anchorY: axis('y'),
    );
  }

  /// The rect the clip would occupy at `scale` 100 — the yardstick a gizmo drag
  /// is converted back into a scale percentage with.
  Rect? clipUnitRectInSequence(Clip clip) {
    final size = gizmoSourceSize(clip);
    if (size == null) return null;
    return layerRectInSequence(
      seqW: doc.settings.width,
      seqH: doc.settings.height,
      srcW: size.$1,
      srcH: size.$2,
      framing: clip.text != null ? 'native' : clip.transformOrDefault.framing,
      x: 0,
      y: 0,
      scalePercent: 100,
    );
  }

  double clipRotation(Clip clip) =>
      evalTransformNum(clip.transformOrDefault.rotation, clip, 0);

  /// The footprint the clip actually claims on the canvas: its rect after
  /// rotation, as an axis-aligned box. This is what align/distribute line up.
  Rect? clipBoundsInSequence(Clip clip) {
    final rect = clipRectInSequence(clip);
    return rect == null ? null : rotatedBounds(rect, clipRotation(clip));
  }

  // --- Align & distribute (FX-15) -------------------------------------------

  /// Selected clips the layout ops can move: gizmo-eligible (visual, probed, on
  /// an unlocked visible video track, spanning the playhead), front-most first.
  List<Clip> alignableClips() =>
      gizmoClipsUnderPlayhead().where((c) => selection.contains(c.id)).toList();

  /// The frame a single-clip align lines up against: the whole sequence canvas.
  Rect get sequenceRect => Rect.fromLTWH(
    0,
    0,
    doc.settings.width.toDouble(),
    doc.settings.height.toDouble(),
  );

  /// Lines the selected images up on [edge]. With one clip selected the
  /// reference is the sequence canvas; with several it is their combined
  /// bounding box, the way every design tool behaves.
  void alignClips(AlignEdge edge) {
    final (clips, bounds) = _layoutTargets();
    if (clips.isEmpty) return;
    _applyLayoutDeltas(
      clips,
      alignDeltas(bounds, edge, frame: clips.length == 1 ? sequenceRect : null),
      'Align clips',
    );
  }

  /// Spreads the selected images so the gaps between them along [axis] are
  /// equal. The outermost two stay put, so it needs three to do anything.
  void distributeClips(AlignAxis axis) {
    final (clips, bounds) = _layoutTargets();
    if (clips.length < 3) return;
    _applyLayoutDeltas(
      clips,
      distributeDeltas(bounds, axis),
      'Distribute clips',
    );
  }

  /// The clips a layout op moves paired with their canvas footprints, dropping
  /// any whose bounds cannot be measured.
  (List<Clip>, List<Rect>) _layoutTargets() {
    final clips = <Clip>[];
    final bounds = <Rect>[];
    for (final clip in alignableClips()) {
      final b = clipBoundsInSequence(clip);
      if (b == null) continue;
      clips.add(clip);
      bounds.add(b);
    }
    return (clips, bounds);
  }

  /// Translates each clip by its delta, as one undo step. Writes rebase like a
  /// gizmo drag so a clip carrying a generated image animation moves its
  /// resting pose instead of writing a key the next rebuild would discard.
  void _applyLayoutDeltas(List<Clip> clips, List<Offset> deltas, String label) {
    if (deltas.length != clips.length) return;
    if (deltas.every((d) => d.dx.abs() < 0.5 && d.dy.abs() < 0.5)) return;
    beginGesture(label);
    for (var i = 0; i < clips.length; i += 1) {
      final delta = deltas[i];
      if (delta == Offset.zero) continue;
      final clip = clips[i];
      final resting = clipAnimationResting(clip);
      final at = clipLocalTime(clip);
      if (delta.dx != 0) {
        setTransformParam(
          clip.id,
          'x',
          resting['x']! + delta.dx,
          at: at,
          rebase: true,
        );
      }
      if (delta.dy != 0) {
        setTransformParam(
          clip.id,
          'y',
          resting['y']! + delta.dy,
          at: at,
          rebase: true,
        );
      }
    }
    endGesture();
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
    final width = previewRenderWidth;
    // Same document, same time, same size: the composite would be pixel-for-
    // pixel what the monitor is already showing.
    final key = (revision, requested.micros, width);
    if (key == _shownKey) return;
    final seq = ++_requestSeq;

    _framesInFlight++;
    try {
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
        if (raster == null) {
          _textGizmoSizes.remove(clip.id);
          continue;
        }
        final sequenceScale = doc.settings.height / height;
        _textGizmoSizes[clip.id] = (
          (raster.width * sequenceScale).round(),
          (raster.height * sequenceScale).round(),
        );
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
        requestSeq: seq,
        shownSeq: _shownSeq,
      );
      if (current) {
        // One targeted repaint of the monitor. Nothing else on screen depends
        // on the frame, so nothing else is rebuilt.
        _shownSeq = seq;
        _shownKey = key;
        previewImage.value = frame;
      }
    } catch (e) {
      debugPrint('preview frame failed: $e');
    } finally {
      _framesInFlight--;
    }
    if (_disposed) return;
    // A move that arrived while this frame was in flight: push the document it
    // produced now, so the drag always ends on the newest pose.
    if (_liveEditPending && inGesture) {
      _pushLivePreview();
      return;
    }
    if (_framePending) {
      _framePending = false;
      // Deliberately not awaited: awaiting here nests one pending future per
      // composited frame, so a few minutes of playback builds a chain
      // thousands deep that only unwinds when the transport stops.
      unawaited(updatePreviewFrame());
    }
  }

  // --- Persistence ----------------------------------------------------------

  @override
  void markDirty() {
    // Mid-drag the document changes every frame; the engine only needs the
    // committed result, which endGesture() delivers.
    if (!inGesture) {
      _liveEditing = false;
      _liveEditPending = false;
      _syncEngineGraph();
    }
    autosave.markDirty();
  }

  /// True between the first [previewLiveEdit] of a gesture and its commit.
  bool _liveEditing = false;
  bool _liveEditPending = false;

  /// Width the next preview frame renders at, given what the transport and the
  /// pointer are doing.
  int get previewRenderWidth {
    final cap =
        playing
            ? maxPlaybackPreviewWidth
            : _liveEditing
            ? maxLiveEditPreviewWidth
            : _previewWidth;
    return cap < _previewWidth ? cap : _previewWidth;
  }

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
    final first = !_liveEditing;
    _liveEditing = true;
    // Paced by the renderer, not by a clock: a pointer emits moves far faster
    // than a frame can be composited, and a fixed interval either wastes
    // encodes or leaves the last one waiting on a timer. One push per completed
    // frame is both the freshest and the cheapest schedule.
    if (_frameBusy && !first) {
      _liveEditPending = true;
      return;
    }
    _pushLivePreview();
  }

  /// A gesture that ended without committing anything (a click, a drag that
  /// resolved to no change) never reaches [markDirty], so the live-edit state
  /// is cleared here too — otherwise the monitor would stay at the reduced
  /// drag resolution until the next edit.
  @override
  void endGesture() {
    super.endGesture();
    if (!_liveEditing) return;
    _liveEditing = false;
    _liveEditPending = false;
    _syncEngineGraph();
  }

  void _pushLivePreview() {
    if (_disposed) return;
    _liveEditPending = false;
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
