import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:crazycut_app/modules/project/infrastructure/repository.dart';

/// Application-scoped UI choices that should survive project changes and
/// relaunches. Project content remains in the project document; this store is
/// the way the editor is presented and operated.
class UiPreferences extends ChangeNotifier {
  UiPreferences({this.storageDirOverride});

  static final UiPreferences instance = UiPreferences();

  final Directory? storageDirOverride;

  bool _loaded = false;
  Future<void>? _loading;
  bool get loaded => _loaded;

  bool timelineSnap = true;
  double timelinePixelsPerSecond = 40;
  bool mediaPoolListView = false;
  bool magneticTimeline = false;
  bool linkAudioOnAdd = true;
  String previewZoom = 'fit';
  String previewQuality = 'auto';
  bool showSafeMargins = false;
  bool showCanvasGrid = false;
  bool generateProxies = true;
  String outputDeviceName = '';

  String? _pendingJson;
  Future<void>? _writer;

  Future<Directory> _dir() async {
    if (storageDirOverride != null) return storageDirOverride!;
    try {
      return await ProjectRepository.projectsDir();
    } catch (_) {
      return await getApplicationSupportDirectory();
    }
  }

  Future<File> _file() async => File(
    '${(await _dir()).path}${Platform.pathSeparator}.ui-preferences.json',
  );

  Future<void> load() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      timelineSnap = decoded['timelineSnap'] as bool? ?? timelineSnap;
      timelinePixelsPerSecond = ((decoded['timelinePixelsPerSecond'] as num?)
                  ?.toDouble() ??
              timelinePixelsPerSecond)
          .clamp(8, 160);
      mediaPoolListView =
          decoded['mediaPoolListView'] as bool? ?? mediaPoolListView;
      magneticTimeline =
          decoded['magneticTimeline'] as bool? ?? magneticTimeline;
      linkAudioOnAdd = decoded['linkAudioOnAdd'] as bool? ?? linkAudioOnAdd;
      previewZoom = decoded['previewZoom'] as String? ?? previewZoom;
      previewQuality = decoded['previewQuality'] as String? ?? previewQuality;
      showSafeMargins = decoded['showSafeMargins'] as bool? ?? showSafeMargins;
      showCanvasGrid = decoded['showCanvasGrid'] as bool? ?? showCanvasGrid;
      generateProxies = decoded['generateProxies'] as bool? ?? generateProxies;
      outputDeviceName =
          decoded['outputDeviceName'] as String? ?? outputDeviceName;
    } on Object {
      // Invalid preferences should never keep the editor from opening.
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  Map<String, dynamic> _toJson() => {
    'timelineSnap': timelineSnap,
    'timelinePixelsPerSecond': timelinePixelsPerSecond,
    'mediaPoolListView': mediaPoolListView,
    'magneticTimeline': magneticTimeline,
    'linkAudioOnAdd': linkAudioOnAdd,
    'previewZoom': previewZoom,
    'previewQuality': previewQuality,
    'showSafeMargins': showSafeMargins,
    'showCanvasGrid': showCanvasGrid,
    'generateProxies': generateProxies,
    'outputDeviceName': outputDeviceName,
  };

  void _changed() {
    notifyListeners();
    _pendingJson = jsonEncode(_toJson());
    _writer ??= _drainWrites();
  }

  Future<void> _drainWrites() async {
    while (_pendingJson != null) {
      final json = _pendingJson!;
      _pendingJson = null;
      try {
        final file = await _file();
        await file.parent.create(recursive: true);
        await file.writeAsString(json, flush: true);
      } on Object {
        // Preferences are best effort and must not interrupt editing.
      }
    }
    _writer = null;
  }

  /// Waits until the latest coalesced write reaches disk. Exposed for orderly
  /// shutdown and deterministic tests.
  Future<void> flush() async {
    while (_writer != null) {
      await _writer;
    }
  }

  void setTimelineSnap(bool value) {
    if (timelineSnap == value) return;
    timelineSnap = value;
    _changed();
  }

  void setTimelinePixelsPerSecond(double value) {
    final clamped = value.clamp(8.0, 160.0);
    if (timelinePixelsPerSecond == clamped) return;
    timelinePixelsPerSecond = clamped;
    _changed();
  }

  void setMediaPoolListView(bool value) {
    if (mediaPoolListView == value) return;
    mediaPoolListView = value;
    _changed();
  }

  void setMagneticTimeline(bool value) {
    if (magneticTimeline == value) return;
    magneticTimeline = value;
    _changed();
  }

  void setLinkAudioOnAdd(bool value) {
    if (linkAudioOnAdd == value) return;
    linkAudioOnAdd = value;
    _changed();
  }

  void setPreviewZoom(String value) {
    if (previewZoom == value) return;
    previewZoom = value;
    _changed();
  }

  void setPreviewQuality(String value) {
    if (previewQuality == value) return;
    previewQuality = value;
    _changed();
  }

  void setShowSafeMargins(bool value) {
    if (showSafeMargins == value) return;
    showSafeMargins = value;
    _changed();
  }

  void setShowCanvasGrid(bool value) {
    if (showCanvasGrid == value) return;
    showCanvasGrid = value;
    _changed();
  }

  void setGenerateProxies(bool value) {
    if (generateProxies == value) return;
    generateProxies = value;
    _changed();
  }

  void setOutputDeviceName(String value) {
    if (outputDeviceName == value) return;
    outputDeviceName = value;
    _changed();
  }
}
