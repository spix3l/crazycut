import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset, Rect;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'package:crazycut_app/modules/project/infrastructure/autosave.dart';
import 'package:crazycut_app/modules/project/domain/caption.dart';
import 'package:crazycut_app/modules/media/infrastructure/cache_dir.dart';
import 'package:crazycut_app/modules/project/domain/param_value.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/media/infrastructure/remote_source_cache.dart';
import 'package:crazycut_app/modules/project/infrastructure/repository.dart';
import 'package:crazycut_app/modules/project/domain/template.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/project/domain/area_track.dart';
import 'package:crazycut_app/modules/editor/application/area_track_edits.dart';
import 'package:crazycut_app/modules/editor/application/audio_edits.dart';
import 'package:crazycut_app/modules/editor/application/editor_dependencies.dart';
import 'package:crazycut_app/modules/editor/infrastructure/tracking_service.dart';
import 'package:crazycut_app/modules/editor/application/auto_captions.dart';
import 'package:crazycut_app/modules/editor/application/caption_edits.dart';
import 'package:crazycut_app/modules/editor/infrastructure/caption_rasterizer.dart';
import 'package:crazycut_app/modules/editor/domain/canvas_geometry.dart';
import 'package:crazycut_app/modules/media/application/clipboard_media.dart';
import 'package:crazycut_app/modules/editor/infrastructure/preview_renderer.dart';
import 'package:crazycut_app/modules/projects/application/project_tools.dart';
import 'package:crazycut_app/modules/media/application/proxy_service.dart';
import 'package:crazycut_app/modules/media/application/media_url_service.dart';
import 'package:crazycut_app/modules/editor/infrastructure/svg_rasterizer.dart';
import 'package:crazycut_app/modules/editor/application/template_edits.dart';
import 'package:crazycut_app/modules/editor/application/timeline_edits.dart';
import 'package:crazycut_app/modules/ai/application/transcription_service.dart';
import 'package:crazycut_app/modules/settings/application/ui_preferences.dart';

part 'auto_caption_result.dart';
part 'clipboard_import_kind.dart';
part 'clipboard_import_result.dart';
part 'import_status.dart';
part 'pool_item.dart';
part 'preview_quality.dart';
part 'preview_zoom.dart';
part 'url_import_kind.dart';
part 'url_import_result.dart';

/// Everything the editor screen reads and writes for one open project:
/// document edits (via [TimelineEdits]), the media pool, playback, the preview
/// frame, autosave and proxies.
class EditorController extends ChangeNotifier
    with
        TimelineEdits,
        CaptionEdits,
        AudioEdits,
        TemplateEdits,
        AreaTrackEdits {
  static final EditorDependencies _productionDependencies =
      EditorDependencies.production();

  EditorController(
    this.doc, {
    required String path,
    ProxyService? proxies,
    ClipboardMediaReader? clipboard,
    UiPreferences? uiPreferences,
    EditorDependencies? dependencies,
  }) : proxies = proxies ?? ProxyService(),
       clipboard = clipboard ?? const SystemClipboardMediaReader(),
       dependencies = dependencies ?? _productionDependencies,
       uiPreferences =
           uiPreferences ?? (dependencies ?? _productionDependencies).preferences,
       _ownsProxies = proxies == null {
    magnetic = this.uiPreferences.magneticTimeline;
    linkAudioOnAdd = this.uiPreferences.linkAudioOnAdd;
    previewZoom = PreviewZoom.values.firstWhere(
      (value) => value.name == this.uiPreferences.previewZoom,
      orElse: () => PreviewZoom.fit,
    );
    previewQuality = PreviewQuality.values.firstWhere(
      (value) => value.name == this.uiPreferences.previewQuality,
      orElse: () => PreviewQuality.auto,
    );
    showSafeMargins = this.uiPreferences.showSafeMargins;
    showCanvasGrid = this.uiPreferences.showCanvasGrid;
    outputDeviceName = this.uiPreferences.outputDeviceName;
    autosave = ProjectAutosave(
      doc,
      path: path,
      onStateChanged: (_) => notifyListeners(),
    );
    this.proxies.addListener(notifyListeners);
    for (final asset in doc.media) {
      final exists =
          asset.isRemote ||
          (asset.path.isNotEmpty && File(asset.path).existsSync());
      asset.offline = !exists;
      pool[asset.id] = PoolItem(
        asset: asset,
        status: exists ? ImportStatus.ready : ImportStatus.offline,
      );
      if (exists) this.proxies.request(asset);
    }
    migrateLegacyTextAnimations();
    _syncEngineGraph();
    unawaited(_prepareMedia());
    unawaited(_bootRenderer());
  }

  /// Re-checks assets that read as offline, for use after a sandbox grant is
  /// restored or newly given. An asset is only offline because its file could
  /// not be reached, and a folder grant can change that answer without
  /// anything on disk having moved.
  void recheckOfflineAssets() {
    var changed = false;
    for (final asset in doc.media) {
      if (!asset.offline || asset.isRemote) continue;
      if (asset.path.isEmpty || !File(asset.path).existsSync()) continue;
      asset.offline = false;
      proxies.request(asset);
      final item = pool[asset.id];
      if (item != null) {
        item.status = ImportStatus.ready;
        unawaited(_loadThumbnailInto(item));
      }
      changed = true;
    }
    if (changed) {
      _syncEngineGraph();
      notifyListeners();
    }
  }

  @override
  final ProjectDoc doc;

  late final ProjectAutosave autosave;
  final ProxyService proxies;
  final ClipboardMediaReader clipboard;
  final EditorDependencies dependencies;
  final UiPreferences uiPreferences;
  MediaUrlService get mediaUrls => dependencies.mediaUrls;
  TranscriptionService get transcription => dependencies.transcription;

  bool _autoCaptionBusy = false;
  String? _autoCaptionAssetId;
  bool get autoCaptionBusy => _autoCaptionBusy;
  AutoCaptionSource? get autoCaptionSource =>
      chooseAutoCaptionSource(doc, selectedClip);
  TranscriptionJob? get autoCaptionJob => _autoCaptionAssetId == null
      ? null
      : transcription.jobFor(_autoCaptionAssetId!);

  Future<AutoCaptionResult> generateAutoCaptions() async {
    if (_autoCaptionBusy) {
      return const AutoCaptionResult(error: 'Captions are already generating.');
    }
    final source = autoCaptionSource;
    if (source == null) {
      return const AutoCaptionResult(
        error: 'Add or select a timeline clip with available audio first.',
      );
    }

    _autoCaptionBusy = true;
    _autoCaptionAssetId = source.asset.id;
    transcription.addListener(notifyListeners);
    notifyListeners();
    try {
      final transcript = await transcription.ensure(source.asset);
      final job = transcription.jobFor(source.asset.id);
      if (job?.state == TranscriptionState.cancelled) {
        return const AutoCaptionResult(cancelled: true);
      }
      if (transcript == null) {
        return AutoCaptionResult(
          error: job?.error ?? 'The clip could not be transcribed.',
        );
      }
      final generated = captionsForClip(
        transcript,
        source.clip,
        trackId: generateId(),
        trackName: doc.captionTracks.isEmpty
            ? 'Auto captions'
            : 'Auto captions ${doc.captionTracks.length + 1}',
      );
      if (generated.track.items.isEmpty) {
        return const AutoCaptionResult(
          error: 'No speech was found inside the visible part of this clip.',
        );
      }
      addCaptionTrackFrom(generated.track);
      return AutoCaptionResult(track: generated.track);
    } finally {
      transcription.removeListener(notifyListeners);
      _autoCaptionBusy = false;
      _autoCaptionAssetId = null;
      if (!_disposed) notifyListeners();
    }
  }

  void cancelAutoCaptions() {
    final assetId = _autoCaptionAssetId;
    if (assetId != null) transcription.cancel(assetId);
  }

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
  final ValueNotifier<(double, double)> audioLevelsNotifier = ValueNotifier((
    0,
    0,
  ));
  (double, double) get audioLevels => audioLevelsNotifier.value;
  set audioLevels((double, double) value) => audioLevelsNotifier.value = value;

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
      _catalogCache = dependencies.engine.effectCatalog();
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

  /// UIX 3.2 monitor zoom: Fit scales the canvas to the available space;
  /// the fixed levels show it at that fraction of sequence resolution and
  /// let the monitor scroll if it doesn't fit.
  PreviewZoom previewZoom = PreviewZoom.fit;

  void setPreviewZoom(PreviewZoom value) {
    if (previewZoom == value) return;
    previewZoom = value;
    uiPreferences.setPreviewZoom(value.name);
    notifyListeners();
  }

  /// UIX 3.2 playback quality dropdown. Auto is the existing adaptive
  /// behavior below (full res when parked, capped while playing or
  /// mid-gesture); the fixed tiers hold [previewRenderWidth] at a fraction
  /// of [_previewWidth] regardless of transport state.
  PreviewQuality previewQuality = PreviewQuality.auto;

  void setPreviewQuality(PreviewQuality value) {
    if (previewQuality == value) return;
    previewQuality = value;
    uiPreferences.setPreviewQuality(value.name);
    _previewRevision++;
    notifyListeners();
    unawaited(updatePreviewFrame());
  }

  /// UIX 3.2 canvas overlay toggles.
  bool showSafeMargins = false;
  bool showCanvasGrid = false;

  void setShowSafeMargins(bool value) {
    if (showSafeMargins == value) return;
    showSafeMargins = value;
    uiPreferences.setShowSafeMargins(value);
    notifyListeners();
  }

  void setShowCanvasGrid(bool value) {
    if (showCanvasGrid == value) return;
    showCanvasGrid = value;
    uiPreferences.setShowCanvasGrid(value);
    notifyListeners();
  }

  @override
  void setMagnetic(bool value) {
    if (magnetic == value) return;
    super.setMagnetic(value);
    uiPreferences.setMagneticTimeline(value);
  }

  @override
  void setLinkAudioOnAdd(bool value) {
    if (linkAudioOnAdd == value) return;
    super.setLinkAudioOnAdd(value);
    uiPreferences.setLinkAudioOnAdd(value);
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
    cancelAutoCaptions();
    transcription.removeListener(notifyListeners);
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
    mediaUrls.close();
    if (_ownsProxies) proxies.dispose();
    autosave.dispose();
    super.dispose();
  }

  Future<void> close() async {
    _disposed = true;
    cancelAutoCaptions();
    transcription.removeListener(notifyListeners);
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

  /// Expands folders, drops unsupported files and imports the rest
  /// (IMP-1/2/4). Returns how many files were accepted.
  Future<int> importPaths(
    List<String> paths, {
    bool addToTimeline = false,
  }) async {
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
    if (files.isNotEmpty) {
      await importFiles(files, addToTimeline: addToTimeline);
    }
    if (skipped.isNotEmpty) notifyListeners();
    return files.length;
  }

  bool _supported(String path) =>
      kSupportedExtensions.contains(path.split('.').last.toLowerCase());

  /// Imports [path] and returns the asset it resolves to.
  ///
  /// Not the same as "the asset that appeared": **IMP-3** dedupes by content
  /// hash, so re-importing something already in the project selects the
  /// existing asset and adds nothing. Callers that diff the media list before
  /// and after therefore find nothing and conclude the import failed — which
  /// is how "replace with image" worked the first time and silently did
  /// nothing every time after.
  Future<MediaAsset?> importAndResolve(String path) async {
    final before = {for (final m in doc.media) m.id};
    await importPaths([path]);
    final added = doc.media.where((m) => !before.contains(m.id));
    if (added.isNotEmpty) return added.last;
    // Deduped, or already present: find what it collapsed onto.
    try {
      final hash = dependencies.engine.hashFile(path);
      final match = doc.media.firstWhereOrNull((m) => m.hash == hash);
      if (match != null) return match;
    } on Object {
      // An unreadable file falls through to the path match, which is the
      // honest answer when hashing is not available.
    }
    return doc.media.firstWhereOrNull((m) => m.path == path);
  }

  /// With [addToTimeline] every imported asset also lands on the timeline at
  /// the playhead, one after another so a multi-file paste keeps its order,
  /// pushing whatever sat there to the right. The playhead itself does not
  /// move: the user is still looking at the frame they pasted onto.
  Future<void> importFiles(
    List<String> paths, {
    bool addToTimeline = false,
  }) async {
    var at = playhead;
    void place(String assetId) {
      final created = placeAsset(assetId, at: at, mode: DropMode.insert);
      final clip = created.isEmpty ? null : doc.clipById(created.first);
      if (clip != null) at = at.plus(clip.duration);
    }

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
      // The picker granted this file for this run only; a bookmark is what
      // carries that grant across relaunches.
      await dependencies.sandbox.remember(path);
      pool[asset.id] = PoolItem(asset: asset);
      notifyListeners();
      try {
        final hash = dependencies.engine.hashFile(path);
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
          if (addToTimeline) place(duplicate.id);
          notifyListeners();
          continue;
        }
        asset.hash = hash;
        Uint8List? svgThumb;
        if (svg) {
          final raster = await dependencies.svgRasterizer.rasterize(
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
          final probe = dependencies.engine.probeFile(path);
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
        if (addToTimeline) place(asset.id);
      } catch (e) {
        pool[asset.id]?.status = ImportStatus.failed;
        debugPrint('import failed for $path: $e');
      }
    }
    markDirty();
    notifyListeners();
  }

  /// Imports a direct public media URL, or stores a YouTube link as a
  /// reference-only item. YouTube references never enter the render graph.
  Future<UrlImportResult> importUrl(String value) async {
    final youtube = parseYouTubeLink(value);
    if (youtube != null) {
      final existing = doc.references.firstWhereOrNull(
        (item) =>
            item.provider == 'youtube' && item.externalId == youtube.videoId,
      );
      if (existing != null) {
        return UrlImportResult(UrlImportKind.duplicate, existing.id);
      }
      final reference = MediaReference(
        id: generateId(),
        provider: 'youtube',
        url: normalizeRemoteUrl(value),
        externalId: youtube.videoId,
        rangeIn: Rt.fromSeconds(youtube.startSeconds.toDouble()),
      );
      doc.references.add(reference);
      markDirty();
      notifyListeners();
      return UrlImportResult(UrlImportKind.youtubeReference, reference.id);
    }

    final descriptor = await mediaUrls.inspect(value);
    final duplicate = doc.media.firstWhereOrNull(
      (asset) => asset.isRemote && asset.path == descriptor.enteredUrl,
    );
    if (duplicate != null) {
      return UrlImportResult(UrlImportKind.duplicate, duplicate.id);
    }

    final asset = MediaAsset(
      id: generateId(),
      name: descriptor.name,
      path: descriptor.enteredUrl,
      type: 'video',
      duration: Rt.zero(),
      hasAudio: false,
      sourceKind: MediaSourceKind.url,
      remoteEtag: descriptor.etag,
      remoteLastModified: descriptor.lastModified,
      remoteContentLength: descriptor.contentLength,
    );
    final item = PoolItem(asset: asset);
    pool[asset.id] = item;
    notifyListeners();
    try {
      Uint8List? svgThumb;
      final svg =
          descriptor.contentType == 'image/svg+xml' ||
          isSvgPath(descriptor.resolvedUrl);
      if (svg) {
        final raster = await dependencies.svgRasterizer.rasterize(
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
        svgThumb = raster.png;
      } else {
        final probe = await mediaUrls.probe(descriptor);
        _applyProbe(asset, probe);
      }
      asset.thumbStatus = ThumbStatus.pending;
      doc.media.add(asset);
      item
        ..status = ImportStatus.ready
        ..thumb = svgThumb;
      unawaited(_mirrorRemoteSource(item));
      unawaited(_loadThumbnailInto(item));
      markDirty();
      notifyListeners();
      return UrlImportResult(UrlImportKind.media, asset.id);
    } on Object {
      pool.remove(asset.id);
      notifyListeners();
      rethrow;
    }
  }

  // --- Paste (IMP-1) --------------------------------------------------------

  /// Imports whatever the system clipboard is holding — files copied in a file
  /// manager, a raw bitmap (a screenshot, an image copied out of a browser), or
  /// a media URL — and drops it on the timeline at the playhead.
  ///
  /// Pasting is a placement, not a filing action: the media lands where the
  /// user is looking, the way pasting anything else does.
  ///
  /// Returns [ClipboardImportKind.nothing] when the clipboard has nothing the
  /// editor wants, so Cmd+V can fall through to the timeline's own paste.
  ///
  /// [onlyIfNewerThanCopy] is for that shared Cmd+V, and it is deliberately
  /// hard to satisfy: once clips have been copied inside the app the keystroke
  /// stays theirs unless real media — a file or a bitmap, never text — landed
  /// on the system clipboard *after* the copy, proven by the host's clipboard
  /// generation. Anything less certain (no generation counter, a mark still in
  /// flight, a URL sitting there since this morning) pastes the clips, because
  /// a clip paste that silently turned into an import is the worse failure.
  Future<ClipboardImportResult> importFromClipboard({
    bool onlyIfNewerThanCopy = false,
  }) async {
    final media = await clipboard.read();
    if (onlyIfNewerThanCopy && hasClipboard && !_beatsClipCopy(media)) {
      return const ClipboardImportResult(ClipboardImportKind.nothing);
    }

    if (media.paths.isNotEmpty) {
      final present = media.paths
          .where(
            (path) =>
                FileSystemEntity.typeSync(path) !=
                FileSystemEntityType.notFound,
          )
          .toList();
      if (present.isNotEmpty) {
        final imported = await importPaths(present, addToTimeline: true);
        return ClipboardImportResult(
          imported > 0
              ? ClipboardImportKind.files
              : ClipboardImportKind.unsupported,
          count: imported,
        );
      }
    }

    final bytes = media.image;
    if (bytes != null && bytes.isNotEmpty) return _importPastedImage(media);

    final text = media.text?.trim();
    if (text == null || text.isEmpty) {
      return const ClipboardImportResult(ClipboardImportKind.nothing);
    }
    final local = _localPathFromText(text);
    if (local != null) {
      final imported = await importPaths([local], addToTimeline: true);
      return ClipboardImportResult(
        imported > 0
            ? ClipboardImportKind.files
            : ClipboardImportKind.unsupported,
        count: imported,
      );
    }
    if (!_looksLikeHttpUrl(text)) {
      return const ClipboardImportResult(ClipboardImportKind.nothing);
    }
    try {
      final result = await importUrl(text);
      // A YouTube link is a reference, not a source: it can never sit on the
      // timeline (IMP-1b), so there is nothing to place.
      if (result.kind != UrlImportKind.youtubeReference) {
        placeAsset(result.id, at: playhead, mode: DropMode.insert);
      }
      return const ClipboardImportResult(ClipboardImportKind.url, count: 1);
    } on Object catch (e) {
      return ClipboardImportResult(
        ClipboardImportKind.url,
        error: e.toString(),
      );
    }
  }

  /// A pasted bitmap has no file behind it, so it is written into the project's
  /// own `Media/` folder first — the same place "collect media" would put it,
  /// which keeps the project folder self-contained and the paste re-openable.
  Future<ClipboardImportResult> _importPastedImage(ClipboardMedia media) async {
    try {
      final directory = path.isEmpty
          ? Directory(
              '${(await mediaCacheDirectory()).path}'
              '${Platform.pathSeparator}Pasted',
            )
          : ProjectTools.mediaFolder(path);
      final file = await writePastedImage(
        media.image!,
        directory: directory,
        extension: media.imageExtension,
      );
      final imported = await importPaths([file.path], addToTimeline: true);
      if (imported > 0 &&
          !pool.values.any((item) => item.asset.path == file.path)) {
        // The same bitmap was already in the project, so the import
        // deduplicated onto the existing asset (IMP-3) and nothing points at
        // the copy: pasting a screenshot twice must not litter the folder.
        try {
          await file.delete();
        } on Object catch (e) {
          debugPrint('pasted image cleanup failed: $e');
        }
      }
      return ClipboardImportResult(
        imported > 0
            ? ClipboardImportKind.image
            : ClipboardImportKind.unsupported,
        count: imported,
      );
    } on Object catch (e) {
      debugPrint('pasted image import failed: $e');
      return ClipboardImportResult(
        ClipboardImportKind.image,
        error: 'The pasted image could not be saved: $e',
      );
    }
  }

  /// A path copied as text, or dropped in as a `file://` URL. Returns null for
  /// anything that is not an existing file on this machine.
  static String? _localPathFromText(String text) {
    var candidate = text;
    if (candidate.startsWith('file://')) {
      try {
        candidate = Uri.parse(candidate).toFilePath();
      } on Object {
        return null;
      }
    }
    if (candidate.contains('\n')) return null;
    return File(candidate).existsSync() ? candidate : null;
  }

  static bool _looksLikeHttpUrl(String text) {
    final uri = Uri.tryParse(text);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  /// Whether [media] outranks the clips sitting on the app's own clipboard.
  ///
  /// Both generations have to be known and different: the host must have a
  /// counter, the mark taken at copy time must have arrived, and the clipboard
  /// must have moved since. Text never qualifies however new it is — a URL is
  /// the thing most likely to be left lying on a clipboard, and it must not
  /// hijack every paste that follows.
  bool _beatsClipCopy(ClipboardMedia media) {
    if (!media.hasMedia) return false;
    final mark = _clipboardSequence;
    return mark != null && media.sequence != null && media.sequence != mark;
  }

  /// Copying clips inside the app records where the system clipboard stood, so
  /// a later paste can tell whether the user has copied something new since.
  @override
  void copySelection() {
    super.copySelection();
    // Cleared synchronously: asking the host costs a channel round-trip, and
    // until the answer lands the previous copy's mark would read as "the
    // clipboard has moved on since" for a copy that just happened.
    _clipboardSequence = null;
    unawaited(_markClipboard());
  }

  Future<void> _markClipboard() async {
    final sequence = await clipboard.sequence();
    if (!_disposed) _clipboardSequence = sequence;
  }

  int? _clipboardSequence;

  void _applyProbe(MediaAsset asset, ProbeResult probe) {
    asset
      ..type = probe.type == 'unknown' ? 'video' : probe.type
      ..duration = Rt.fromSeconds(probe.durationSeconds)
      ..hasAudio = probe.hasAudio
      ..width = probe.width
      ..height = probe.height
      ..fps = probe.fps
      ..rotation = probe.rotation
      ..vfr = probe.vfr
      ..codec = probe.codec
      ..hdr = probe.hdr;
  }

  /// Copies a URL source into the media cache, then queues its proxy.
  ///
  /// Preview, filmstrip and export all read [mediaDecodePath], so the moment
  /// the mirror lands they decode from disk: a scrub or a loop stops costing an
  /// HTTP re-read of the whole file, which is what kept URL clips — GIFs worst
  /// of all, having no keyframe to seek to — from playing in the monitor. The
  /// proxy waits for the mirror so the transcode reads the local copy.
  Future<void> _mirrorRemoteSource(PoolItem item) async {
    final asset = item.asset;
    if (!asset.isRemote) return;
    // An SVG is decoded from the bitmap the rasterizer already wrote; mirroring
    // the markup as well would download it for nothing.
    if (isSvgPath(asset.path)) return;
    item.caching = true;
    notifyListeners();
    try {
      final mirrored = await dependencies.remoteSourceCache.ensure(asset);
      if (_disposed) return;
      if (mirrored != null) {
        // The path rides in the document so reopening the project reuses the
        // copy instead of downloading it again.
        markDirty();
      }
    } on Object catch (e) {
      debugPrint('remote source mirror failed: $e');
    } finally {
      item.caching = false;
      if (!_disposed) {
        proxies.request(asset);
        notifyListeners();
        unawaited(updatePreviewFrame());
      }
    }
  }

  Future<void> refreshRemoteAsset(
    String assetId, {
    String? replacement,
    bool markDocument = true,
  }) async {
    final asset = doc.assetById(assetId);
    if (asset == null || !asset.isRemote) return;
    final oldPath = asset.path;
    final oldRevision = asset.remoteRevision;
    if (replacement != null) asset.path = normalizeRemoteUrl(replacement);
    pool[assetId]?.status = ImportStatus.probing;
    notifyListeners();
    try {
      final descriptor = await mediaUrls.inspect(asset.path);
      if (descriptor.revision != oldRevision || asset.path != oldPath) {
        await dependencies.mediaCache.invalidate(asset);
      }
      if (descriptor.contentType == 'image/svg+xml' ||
          isSvgPath(descriptor.resolvedUrl)) {
        asset.extra.remove('svgRasterPath');
        final raster = await dependencies.svgRasterizer.rasterize(
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
      } else {
        final probe = await mediaUrls.probe(descriptor);
        if (probe.type != asset.type) {
          throw MediaUrlException(
            'The refreshed URL is ${probe.type}, but this asset is ${asset.type}.',
          );
        }
        _applyProbe(asset, probe);
        pool[assetId]?.thumb = null;
        unawaited(_loadThumbnailInto(pool[assetId]!));
      }
      asset
        ..remoteEtag = descriptor.etag
        ..remoteLastModified = descriptor.lastModified
        ..remoteContentLength = descriptor.contentLength
        ..offline = false;
      pool[assetId]?.status = ImportStatus.ready;
      // A changed revision invalidated the mirror above; fetch the new bytes.
      final item = pool[assetId];
      if (item != null) unawaited(_mirrorRemoteSource(item));
      if (markDocument) markDirty();
    } on Object {
      if (replacement != null) asset.path = oldPath;
      asset.offline = true;
      pool[assetId]?.status = ImportStatus.offline;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  void removeReference(String id) {
    doc.references.removeWhere((reference) => reference.id == id);
    markDirty();
    notifyListeners();
  }

  void updateReferenceRange(String id, {Rt? rangeIn, Rt? rangeOut}) {
    final reference = doc.references.firstWhereOrNull((item) => item.id == id);
    if (reference == null) return;
    if (rangeIn != null) reference.rangeIn = rangeIn;
    if (rangeOut != null) reference.rangeOut = rangeOut;
    markDirty();
    notifyListeners();
  }

  // --- Templates (TPL-12) ---------------------------------------------------

  /// Resolves a template's media, then inserts it.
  ///
  /// An asset already in the project with the same content hash wins; failing
  /// that the recorded path is imported (probe included, but not placed on the
  /// timeline). Anything still unresolved is left to the ops layer's offline
  /// stand-in, so a template whose footage moved still inserts and can be
  /// relinked afterwards.
  Future<TemplateInsertResult> insertTemplateResolvingMedia(
    ClipTemplate template, {
    Rt? at,
    String? baseTrackId,
    Map<String, String> slotValues = const {},
    DropMode mode = DropMode.insert,
    TemplateEdge? edgeIn,
    TemplateEdge? edgeOut,
  }) async {
    final resolution = <String, String>{};
    for (final ref in template.media) {
      final known = doc.media.firstWhereOrNull(
        (a) =>
            (ref.hash.isNotEmpty && a.hash == ref.hash) ||
            (ref.path.isNotEmpty && a.path == ref.path),
      );
      if (known != null) {
        resolution[ref.id] = known.id;
        continue;
      }
      if (ref.sourceKind == MediaSourceKind.url && ref.path.isNotEmpty) {
        final result = await importUrl(ref.path);
        if (result.kind == UrlImportKind.media ||
            result.kind == UrlImportKind.duplicate) {
          resolution[ref.id] = result.id;
        }
        continue;
      }
      if (ref.path.isEmpty || !File(ref.path).existsSync()) continue;
      final before = doc.media.map((a) => a.id).toSet();
      await importFiles([ref.path], addToTimeline: false);
      final added = doc.media.firstWhereOrNull((a) => !before.contains(a.id));
      if (added != null) resolution[ref.id] = added.id;
    }
    final result = insertTemplate(
      template,
      at: at,
      baseTrackId: baseTrackId,
      slotValues: slotValues,
      mediaResolution: resolution,
      mode: mode,
      edgeIn: edgeIn,
      edgeOut: edgeOut,
    );
    notifyListeners();
    return result;
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
    asset.sourceKind = MediaSourceKind.file;
    await dependencies.sandbox.remember(newPath);
    asset
      ..remoteEtag = null
      ..remoteLastModified = null
      ..remoteContentLength = null;
    asset.offline = !File(newPath).existsSync();
    pool[assetId]?.status = asset.offline
        ? ImportStatus.offline
        : ImportStatus.ready;
    if (!asset.offline) {
      if (isSvgPath(newPath)) {
        asset.extra.remove('svgRasterPath');
        try {
          final raster = await dependencies.svgRasterizer.rasterize(
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
    if (asset.isRemote) {
      await openExternalUrl(asset.path);
      return;
    }
    await revealPath(asset.path);
  }

  Future<void> openExternalUrl(String value) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [value]);
      } else if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', value]);
      } else {
        await Process.run('xdg-open', [value]);
      }
    } on Object catch (error) {
      debugPrint('open URL failed: $error');
    }
  }

  /// Shows any file the app owns in the OS file browser — media, and the
  /// template files the Templates panel lists (TPL-2).
  Future<void> revealPath(String path) async {
    if (path.isEmpty) return;
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', path]);
      } else {
        await Process.run('xdg-open', [File(path).parent.path]);
      }
    } on Object catch (error) {
      debugPrint('reveal failed: $error');
    }
  }

  Future<void> _prepareMedia() async {
    for (final item in pool.values.toList()) {
      if (item.asset.isRemote) {
        try {
          await refreshRemoteAsset(item.asset.id, markDocument: false);
        } on Object catch (e) {
          debugPrint('remote source unavailable: $e');
          continue;
        }
      }
      if (isSvgPath(item.asset.path) &&
          !item.asset.offline &&
          item.thumb == null) {
        try {
          final raster = await dependencies.svgRasterizer.rasterize(
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
    final bytes = await dependencies.mediaCache.thumb(
      item.asset,
      item.asset.duration.seconds > 2 ? 1.0 : 0.0,
      width: 320,
    );
    // The decode outlives a close: a project shut while thumbnails are still
    // coming back must not notify a disposed controller.
    if (bytes == null || _disposed) return;
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
    final cached = dependencies.mediaCache.thumbNow(asset, quantised, width: width);
    if (cached != null) return cached;
    unawaited(
      dependencies.mediaCache.thumb(
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
    final cached = dependencies.mediaCache.peaksNow(asset);
    if (cached != null) return cached;
    unawaited(dependencies.mediaCache.peaks(asset, onReady: notifyListeners));
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

  @override
  void seekToCaption(CaptionItem item) => seekTo(item.start);

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
      _audio = dependencies.engine.createSequencePlayer();
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
      loudness = dependencies.engine.analyzeLoudness(
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
      final peak = dependencies.engine.scanAudioPeak(
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
      return dependencies.engine.audioOutputDevices();
    } catch (_) {
      return const [];
    }
  }

  void setOutputDevice(String name) {
    if (name == outputDeviceName) return;
    outputDeviceName = name;
    uiPreferences.setOutputDeviceName(name);
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

  /// Routes an area-tracking solve through [TrackingService] (**TRK-5**): the
  /// worker sidecar, the export queue's progress/ETA/cancel vocabulary, and no
  /// document mutation until it lands. [AreaTrackEdits] installs the result as
  /// one undoable command.
  @override
  Future<Tracker?> solveTrackedRegion({
    required String trackerId,
    required Clip clip,
    required MediaAsset asset,
    required Quad searchQuad,
    required Rt start,
    required Rt end,
  }) {
    return dependencies.tracking.solve(
      TrackingRequest(
        trackerId: trackerId,
        asset: asset,
        sourceClipId: clip.id,
        searchQuad: searchQuad,
        startTime: start,
        endTime: end,
        sourceIn: clip.sourceIn,
        speed: clip.speedValue,
        // The region is authored in the media's own pixels, so the solver has
        // to know what those are; it cannot infer them from a scaled frame.
        sourceWidth: asset.width ?? 0,
        // Solve at the sequence rate: the path is consumed per rendered frame,
        // and solving finer than the timeline can show is work nobody sees.
        fps: Rt(frameDuration.den, frameDuration.num),
        label: clip.label,
      ),
    );
  }

  /// Clip the on-canvas transform gizmo should target: the selection when it
  /// is a rasterised visual clip under the playhead, otherwise the topmost one.
  @override
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
  @override
  (int, int)? gizmoSourceSize(Clip clip) {
    if (clip.text case final text?) {
      return _textGizmoSizes[clip.id] ??
          dependencies.textRasterizer.measure(
            text,
            canvasWidth: doc.settings.width,
            sequenceHeight: doc.settings.height,
            localSeconds: clipLocalTime(clip).seconds,
            typewriterSeconds: typewriterRevealSeconds(clip),
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
  @override
  Rt clipLocalTime(Clip clip) =>
      playhead.minus(clip.start).clampTo(Rt.zero(), clip.duration);

  /// Evaluates an animatable transform param at the clip-local playhead.
  double evalTransformNum(ParamValue param, Clip clip, double fallback) {
    final v = param.evaluate(clipLocalTime(clip));
    return v is num ? v.toDouble() : fallback;
  }

  /// The clip's unrotated rect in sequence pixels at the current playhead, or
  /// null when the source was never probed.
  @override
  Rect? clipRectInSequence(Clip clip) {
    final size = gizmoSourceSize(clip);
    if (size == null) return null;
    final t = clip.transformOrDefault;
    final anchor = t.anchor.evaluate(clipLocalTime(clip));
    double axis(String key) => anchor is Map && anchor[key] is num
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

  @override
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

  /// True when [clips] is a single clip, or every clip in it belongs to the
  /// same linked group — cases where the selection is really one object, so
  /// aligning it against its own bounding box would be a no-op.
  bool _isSingleObject(List<Clip> clips) {
    if (clips.length <= 1) return true;
    final group = clips.first.linkedGroup;
    return group != null && clips.every((c) => c.linkedGroup == group);
  }

  /// Lines the selected images up on [edge]. A single clip, or a fully linked
  /// group selected together, lines up against the sequence canvas; several
  /// independent clips line up against their combined bounding box, the way
  /// every design tool behaves.
  void alignClips(AlignEdge edge) {
    final (clips, bounds) = _layoutTargets();
    if (clips.isEmpty) return;
    _applyLayoutDeltas(
      clips,
      alignDeltas(
        bounds,
        edge,
        frame: _isSingleObject(clips) ? sequenceRect : null,
      ),
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
        final raster = await dependencies.textRasterizer.render(
          clip.text!,
          canvasWidth: width,
          sequenceHeight: height,
          localSeconds: (requested - clip.start).seconds,
          typewriterSeconds: typewriterRevealSeconds(clip),
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
      // Captions are timeline-native overlays rather than synthetic clips.
      // Only active cues are shaped for this request; the engine reads their
      // normalized placement from the same project snapshot.
      for (final track in doc.captionTracks) {
        for (final item in track.items) {
          if (!(requested >= item.start && requested < item.end)) continue;
          final highlightedWord = activeCaptionWord(track, item, requested);
          final raster = await dependencies.captionRasterizer.render(
            track,
            item,
            canvasWidth: width,
            sequenceHeight: height,
            highlightedWord: highlightedWord,
          );
          if (raster == null) continue;
          final key = captionTextureKey(
            track,
            item,
            highlightedWord: highlightedWord,
          );
          textures[key] = raster.bytes;
          textureSizes[key] = (raster.width, raster.height);
        }
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
    switch (previewQuality) {
      case PreviewQuality.full:
        return _previewWidth;
      case PreviewQuality.half:
      case PreviewQuality.proxy:
        final divisor = previewQuality == PreviewQuality.half ? 2 : 4;
        return (_previewWidth / divisor).round().clamp(
          minPreviewWidth,
          _previewWidth,
        );
      case PreviewQuality.auto:
        final cap = playing
            ? maxPlaybackPreviewWidth
            : _liveEditing
            ? maxLiveEditPreviewWidth
            : _previewWidth;
        return cap < _previewWidth ? cap : _previewWidth;
    }
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
      dependencies.engine.setProjectSnapshot(snapshot);
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

  // --- Silence removal (Clip menu) ------------------------------------------

  /// Cuts silent stretches out of every selected audible clip, using the
  /// cached waveform peaks. One undo step; later clips on the same tracks
  /// slide left so the remaining audio stays contiguous.
  Future<SilenceRemovalResult> removeSilencesFromSelection({
    double threshold = 0.02,
    double minSilenceSeconds = 0.5,
    double paddingSeconds = 0.1,
  }) async {
    final selected = selectedClips;
    if (selected.isEmpty) {
      return const SilenceRemovalResult(
        removed: 0,
        removedSeconds: 0,
        processed: 0,
        message: 'Select a clip on the timeline first.',
      );
    }
    final seen = <String>{};
    final groups = <_SilenceGroup>[];
    for (final clip in selected) {
      if (seen.contains(clip.id)) continue;
      final group =
          doc.linkedWith(clip).where((c) => seen.add(c.id)).toList();
      if (group.isEmpty) continue;
      Clip? primary;
      for (final member in group) {
        final asset = doc.assetById(member.mediaId);
        if (member.text != null || member.reverse) continue;
        if (member.duration.seconds <= 0) continue;
        if (asset == null || !asset.hasAudio || asset.offline) continue;
        primary = member;
        break;
      }
      if (primary == null) continue;
      final ref = primary;
      final aligned =
          group
              .where(
                (member) =>
                    member.text == null &&
                    !member.reverse &&
                    member.start == ref.start &&
                    member.duration == ref.duration,
              )
              .toList();
      if (aligned.isEmpty) continue;
      final asset = doc.assetById(primary.mediaId);
      if (asset == null) continue;
      List<double>? peaks;
      try {
        peaks = await dependencies.mediaCache.peaks(asset);
      } on Object catch (error) {
        debugPrint('silence removal: peaks unavailable: $error');
        continue;
      }
      if (peaks == null || peaks.isEmpty) continue;
      final assetSeconds = asset.duration.seconds;
      final pps = assetSeconds > 0 ? peaks.length / assetSeconds : 20.0;
      if (pps <= 0) continue;
      final cuts = _silenceCuts(
        primary,
        peaks,
        pps,
        threshold: threshold,
        minSilenceSeconds: minSilenceSeconds,
        paddingSeconds: paddingSeconds,
      );
      if (cuts.isEmpty) continue;
      groups.add(_SilenceGroup(primary: primary, members: aligned, cuts: cuts));
    }
    if (groups.isEmpty) {
      return const SilenceRemovalResult(
        removed: 0,
        removedSeconds: 0,
        processed: 0,
        message:
            'No silences of 0.5s or longer were found in the selection.',
      );
    }
    // Right to left, so sliding later clips left never disturbs coordinates
    // of groups still to process.
    groups.sort(
      (a, b) => b.primary.start.compareTo(a.primary.start),
    );
    var removed = 0;
    var removedMicros = 0;
    runEdit('Remove silences', (tx) {
      for (final group in groups) {
        final origin = group.primary;
        var keeps = <(Rt, Rt)>[(origin.start, origin.end)];
        for (final cut in group.cuts) {
          final next = <(Rt, Rt)>[];
          for (final keep in keeps) {
            if (cut.$2 <= keep.$1 || cut.$1 >= keep.$2) {
              next.add(keep);
              continue;
            }
            if (cut.$1 > keep.$1) next.add((keep.$1, cut.$1));
            if (cut.$2 < keep.$2) next.add((cut.$2, keep.$2));
          }
          keeps = next;
        }
        keeps =
            keeps
                .where((keep) => keep.$2.minus(keep.$1) >= frameDuration)
                .toList();
        if (keeps.isEmpty) continue;
        Rt removedBefore(Rt t) {
          var total = Rt.zero();
          for (final cut in group.cuts) {
            if (cut.$2 <= t) total = total.plus(cut.$2.minus(cut.$1));
          }
          return total;
        }

        var totalRemoved = Rt.zero();
        for (final cut in group.cuts) {
          totalRemoved = totalRemoved.plus(cut.$2.minus(cut.$1));
        }
        removed += group.cuts.length;
        removedMicros += totalRemoved.micros;

        final sharedGroup =
            group.members.length > 1 &&
            group.members.first.linkedGroup != null;
        final segmentGroups = [
          for (var j = 0; j < keeps.length; j++)
            sharedGroup ? generateId() : null,
        ];
        for (final member in group.members) {
          final speed = member.speedValue;
          tx.clip(member.id);
          doc.clips.remove(member);
          selection.remove(member.id);
          for (var j = 0; j < keeps.length; j++) {
            final keep = keeps[j];
            final newStart = member.start
                .plus(keep.$1.minus(origin.start))
                .minus(removedBefore(keep.$1));
            final clone = member.cloneWithNewId(
              trackId: member.trackId,
              start: newStart,
              linkedGroup: segmentGroups[j] ?? member.linkedGroup,
            );
            clone.duration = keep.$2.minus(keep.$1);
            clone.sourceIn = member.sourceIn.plus(
              keep.$1.minus(origin.start).toSourceTime(speed <= 0 ? 1 : speed),
            );
            clone.fadeIn =
                j == 0 ? member.fadeIn.copy() : Fade(duration: Rt.zero());
            clone.fadeOut =
                j == keeps.length - 1
                    ? member.fadeOut.copy()
                    : Fade(duration: Rt.zero());
            tx.clip(clone.id);
            doc.clips.add(clone);
            selection.add(clone.id);
          }
        }
        final shiftedTracks = <String>{};
        for (final member in group.members) {
          if (!shiftedTracks.add(member.trackId)) continue;
          for (final other in doc.clipsOn(member.trackId)) {
            if (other.start >= origin.end) {
              tx.clip(other.id);
              other.start = other.start.minus(totalRemoved);
            }
          }
        }
      }
    });
    return SilenceRemovalResult(
      removed: removed,
      removedSeconds: removedMicros / 1000000,
      processed: groups.length,
    );
  }

  /// Silent source runs inside [clip], as timeline cut points.
  List<(Rt, Rt)> _silenceCuts(
    Clip clip,
    List<double> peaks,
    double pps, {
    required double threshold,
    required double minSilenceSeconds,
    required double paddingSeconds,
  }) {
    final speed = clip.speedValue;
    if (speed <= 0) return const [];
    final sourceStart = clip.sourceIn.seconds;
    final sourceSpan = clip.duration.seconds * speed;
    final sourceEnd = sourceStart + sourceSpan;
    var i0 = (sourceStart * pps).floor();
    var i1 = (sourceEnd * pps).ceil();
    i0 = i0.clamp(0, peaks.length);
    i1 = i1.clamp(0, peaks.length);
    final cuts = <(Rt, Rt)>[];
    var runStart = -1;
    void flush(int runEnd) {
      if (runStart < 0) return;
      final runS0 = runStart / pps;
      final runS1 = runEnd / pps;
      runStart = -1;
      final a = runS0 < sourceStart ? sourceStart : runS0;
      final b = runS1 > sourceEnd ? sourceEnd : runS1;
      if (b - a < minSilenceSeconds) return;
      final cutA = a + paddingSeconds;
      final cutB = b - paddingSeconds;
      if (cutB - cutA < 0.1) return;
      final t0 = clip.start.plus(
        Rt.fromSeconds((cutA - sourceStart) / speed),
      );
      final t1 = clip.start.plus(
        Rt.fromSeconds((cutB - sourceStart) / speed),
      );
      final q0 = quantiseToFrame(t0);
      final q1 = quantiseToFrame(t1);
      if (q1.minus(q0) < frameDuration) return;
      if (q0 < clip.start || q1 > clip.end) return;
      cuts.add((q0, q1));
    }

    for (var i = i0; i < i1; i++) {
      if (peaks[i] < threshold) {
        if (runStart < 0) runStart = i;
      } else {
        flush(i);
      }
    }
    flush(i1);
    return cuts;
  }
}

/// Outcome of [EditorController.removeSilencesFromSelection].
class SilenceRemovalResult {
  const SilenceRemovalResult({
    required this.removed,
    required this.removedSeconds,
    required this.processed,
    this.message,
  });

  /// How many silent stretches were cut.
  final int removed;

  /// Total timeline time removed, in seconds.
  final double removedSeconds;

  /// How many selected clips contained silences.
  final int processed;

  /// Human-readable reason when [removed] is zero.
  final String? message;
}

class _SilenceGroup {
  const _SilenceGroup({
    required this.primary,
    required this.members,
    required this.cuts,
  });

  final Clip primary;
  final List<Clip> members;
  final List<(Rt, Rt)> cuts;
}
