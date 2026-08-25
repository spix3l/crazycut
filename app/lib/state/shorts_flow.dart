/// Drives one "Find shorts" run (SHT-1 … SHT-11).
///
/// Transcribe, then propose, then hold candidates for review. Kept apart from
/// the widget so the sequencing — and the rule that nothing is created until
/// the user accepts — is testable without pumping a UI.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:crazycut_app/ai/ai_settings.dart';
import 'package:crazycut_app/ai/core/llm_provider.dart';
import 'package:crazycut_app/data/media_cache.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/transcript.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/editor_controller.dart';
import 'package:crazycut_app/state/shorts_service.dart';
import 'package:crazycut_app/state/speech_model.dart';
import 'package:crazycut_app/state/transcription_service.dart';

enum ShortsStage {
  /// Nothing has been asked for yet.
  idle,

  /// Waiting on the local speech model.
  transcribing,

  /// Waiting on the model to nominate moments.
  proposing,

  /// Candidates are on screen awaiting accept/reject.
  reviewing,

  /// Finished, cancelled, or failed — [error] and [candidates] say which.
  done,
}

class ShortsFlow extends ChangeNotifier {
  ShortsFlow({
    required this.controller,
    required this.projectPath,
    ShortsService? service,
    TranscriptionService? transcription,
    AiSettings? settings,
    SpeechModelStore? models,
  }) : service = service ?? ShortsService(),
       _transcription = transcription ?? TranscriptionService.instance,
       _settings = settings ?? AiSettings.instance,
       _models = models ?? SpeechModelStore.instance;

  final EditorController controller;
  final String projectPath;
  final ShortsService service;
  final TranscriptionService _transcription;
  final AiSettings _settings;
  final SpeechModelStore _models;

  ShortsStage stage = ShortsStage.idle;
  String? error;
  Transcript? transcript;
  List<ShortCandidate> candidates = const [];
  final Set<int> rejected = {};
  final Map<int, File> accepted = {};

  MediaAsset? asset;
  CancellationToken? _cancel;
  final List<String> _markerIds = [];

  bool get isBusy =>
      stage == ShortsStage.transcribing || stage == ShortsStage.proposing;

  TranscriptionJob? get transcriptionJob =>
      asset == null ? null : _transcription.jobFor(asset!.id);

  List<({int index, ShortCandidate candidate})> get pending => [
    for (var i = 0; i < candidates.length; i++)
      if (!rejected.contains(i) && !accepted.containsKey(i))
        (index: i, candidate: candidates[i]),
  ];

  /// The longest video asset used on the timeline — the recording the user
  /// means when they say "find shorts in this".
  MediaAsset? _primaryAsset() {
    MediaAsset? best;
    for (final clip in controller.doc.clips) {
      if (clip.mediaId.isEmpty) continue;
      final candidate = controller.doc.assetById(clip.mediaId);
      if (candidate == null || !candidate.hasAudio) continue;
      final bestSeconds = best?.duration.seconds ?? -1;
      if ((candidate.duration.seconds) > bestSeconds) best = candidate;
    }
    return best;
  }

  Future<void> start() async {
    if (isBusy) return;
    error = null;
    rejected.clear();
    accepted.clear();
    candidates = const [];
    _cancel = CancellationToken();

    final source = _primaryAsset();
    if (source == null) {
      _fail('This sequence has no clip with sound to look through.');
      return;
    }
    asset = source;

    if (!_settings.configured) {
      _fail('Set up a provider in Settings → AI first.');
      return;
    }

    // Transcribe (or reuse the cache).
    stage = ShortsStage.transcribing;
    notifyListeners();

    final cached = await MediaCache.instance.transcript(source);
    var text = cached;
    if (text == null) {
      final model = speechModelById(_transcription.modelId);
      if (!await _models.isInstalled(model)) {
        _fail(
          'The ${model.label} speech model is not installed '
          '(${model.sizeLabel}). Download it in Settings → AI.',
        );
        return;
      }
      _transcription.addListener(_bump);
      try {
        text = await _transcription.ensure(source);
      } finally {
        _transcription.removeListener(_bump);
      }
    }

    if (_cancel?.isCancelled ?? false) return _cancelled();
    if (text == null) {
      _fail(
        _transcription.jobFor(source.id)?.error ??
            'The recording could not be transcribed.',
      );
      return;
    }
    if (text.isEmpty) {
      _fail('No speech was found in this recording.');
      return;
    }
    transcript = text;

    // Propose.
    stage = ShortsStage.proposing;
    notifyListeners();

    final provider = _settings.createProvider();
    if (provider == null) {
      _fail('Set up a provider in Settings → AI first.');
      return;
    }

    try {
      final proposed = await service.propose(
        provider,
        text,
        cancel: _cancel,
      );
      if (_cancel?.isCancelled ?? false) return _cancelled();
      candidates = proposed;
      _addMarkers();
      stage = ShortsStage.reviewing;
      error = proposed.isEmpty
          ? 'No moments in this recording stand on their own.'
          : null;
    } on LlmCancelledError {
      return _cancelled();
    } on LlmError catch (e) {
      _fail(e.message);
      return;
    } finally {
      provider.dispose();
      notifyListeners();
    }
  }

  void _bump() => notifyListeners();

  /// One undo step for the whole proposal run (SHT-10).
  void _addMarkers() {
    if (candidates.isEmpty) return;
    controller.runEdit('Mark shorts', (tx) {
      for (final c in candidates) {
        final marker = Marker(
          id: generateId(),
          time: Rt.fromSeconds(c.startSec),
          name: c.title.isEmpty ? 'Short' : c.title,
        );
        controller.doc.markers.add(marker);
        tx.marker(marker.id);
        _markerIds.add(marker.id);
      }
    });
  }

  void reject(int index) {
    rejected.add(index);
    final markerIndex = index;
    if (markerIndex < _markerIds.length) {
      controller.removeMarker(_markerIds[markerIndex]);
    }
    notifyListeners();
  }

  void nudge(int index, {double startDelta = 0, double endDelta = 0}) {
    if (index < 0 || index >= candidates.length) return;
    final media = asset?.duration.seconds ?? 0;
    final updated = List<ShortCandidate>.of(candidates);
    updated[index] = nudgeCandidate(
      candidates[index],
      startDelta: startDelta,
      endDelta: endDelta,
      mediaDurationSec: media,
      rules: service.rules,
    );
    candidates = updated;
    notifyListeners();
  }

  /// Sets the editor's in/out range to a candidate so it can be previewed.
  void preview(int index) {
    if (index < 0 || index >= candidates.length) return;
    final c = candidates[index];
    controller.inPoint = Rt.fromSeconds(c.startSec);
    controller.outPoint = Rt.fromSeconds(c.endSec);
    controller.seekTo(Rt.fromSeconds(c.startSec));
  }

  Future<File?> accept(int index) async {
    final source = asset;
    if (source == null || index < 0 || index >= candidates.length) return null;
    try {
      final file = await service.createProject(
        candidates[index],
        source: controller.doc,
        asset: source,
        sourceProjectPath: projectPath,
      );
      accepted[index] = file;
      notifyListeners();
      return file;
    } on Object catch (e) {
      error = 'Could not create the project: $e';
      notifyListeners();
      return null;
    }
  }

  void cancel() {
    _cancel?.cancel();
    final source = asset;
    if (source != null) _transcription.cancel(source.id);
    _cancelled();
  }

  void _cancelled() {
    stage = ShortsStage.done;
    error = null;
    notifyListeners();
  }

  void _fail(String message) {
    error = message;
    stage = ShortsStage.done;
    notifyListeners();
  }
}
