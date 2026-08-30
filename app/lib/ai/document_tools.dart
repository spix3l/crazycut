/// The bridge from tool calls to document edits (AI-15 … AI-17).
///
/// This is the piece that makes the next AI feature cheap. Every mutation in
/// CrazyCut already flows through [EditTransaction], so routing a tool call
/// through the same path means an agent edit is *one undo step* and inherits
/// autosave, backups and invariant validation with no special-casing
/// (TIM-20, PRJ-6–9).
///
/// The set is deliberately small. It exists to keep the loop honest and tested,
/// not to expose the editor — a wider surface should arrive with the feature
/// that needs it, and with its own requirement ids.
library;

import 'package:crazycut_app/ai/agent.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/editor_controller.dart';

/// Read-only tools plus the one mutating tool, ready to hand to [AgentRunner].
List<CcTool> documentTools(EditorController controller) => [
  _GetSequenceInfo(controller),
  _ListClips(controller),
  _SetClipRange(controller),
];

/// Read-only tools only — for agents that should be able to look but not touch.
List<CcTool> readOnlyDocumentTools(EditorController controller) => [
  _GetSequenceInfo(controller),
  _ListClips(controller),
];

class _GetSequenceInfo extends CcTool {
  _GetSequenceInfo(this.c);
  final EditorController c;

  @override
  String get name => 'get_sequence_info';

  @override
  String get description =>
      'Call this first, before reasoning about any timing. Returns the '
      'sequence resolution, frame rate, total duration in seconds, and the '
      'list of tracks with their ids and names.';

  @override
  Map<String, dynamic> get schema => {
    'type': 'object',
    'properties': <String, dynamic>{},
    'required': <String>[],
  };

  @override
  Future<String> run(Map<String, dynamic> args) async {
    final doc = c.doc;
    return encodeToolResult({
      'name': doc.name,
      'width': doc.settings.width,
      'height': doc.settings.height,
      'fps': doc.settings.fpsValue,
      'durationSeconds': doc.sequenceDuration.seconds,
      'tracks': [
        for (final t in doc.tracks)
          {
            'id': t.id,
            'name': t.name,
            'kind': t.kind,
            'locked': t.lock,
            'clipCount': doc.clipsOn(t.id).length,
          },
      ],
    });
  }
}

class _ListClips extends CcTool {
  _ListClips(this.c);
  final EditorController c;

  @override
  String get name => 'list_clips';

  @override
  String get description =>
      'Call this whenever you need to know what is on the timeline, before '
      'proposing or making any change to a clip. Returns every clip with its '
      'id, track, label, and timing in seconds. Optionally filtered to one '
      'track.';

  @override
  Map<String, dynamic> get schema => {
    'type': 'object',
    'properties': {
      'trackId': {
        'type': 'string',
        'description': 'Limit the result to this track id.',
      },
    },
    'required': <String>[],
  };

  @override
  Future<String> run(Map<String, dynamic> args) async {
    final trackId = args['trackId'] as String?;
    final doc = c.doc;
    final clips = trackId == null
        ? doc.clips
        : doc.clips.where((clip) => clip.trackId == trackId);

    if (trackId != null && doc.trackById(trackId) == null) {
      throw ArgumentError('No track with id "$trackId".');
    }

    return encodeToolResult([
      for (final clip in clips)
        {
          'id': clip.id,
          'trackId': clip.trackId,
          'label': clip.label,
          if (clip.mediaId.isNotEmpty) 'mediaId': clip.mediaId,
          'startSeconds': clip.start.seconds,
          'durationSeconds': clip.duration.seconds,
          'sourceInSeconds': clip.sourceIn.seconds,
        },
    ]);
  }
}

class _SetClipRange extends CcTool {
  _SetClipRange(this.c);
  final EditorController c;

  @override
  String get name => 'set_clip_range';

  @override
  String get description =>
      'Move or retime one clip. Use it when the user asks for a clip to start '
      'at a different time or to run for a different length. Times are in '
      'seconds. Omit a field to leave it as it is. This is a single undoable '
      'edit.';

  @override
  Map<String, dynamic> get schema => {
    'type': 'object',
    'properties': {
      'clipId': {
        'type': 'string',
        'description': 'Id of the clip, from list_clips.',
      },
      'startSeconds': {
        'type': 'number',
        'description': 'New position on the timeline.',
      },
      'durationSeconds': {
        'type': 'number',
        'description': 'New length on the timeline.',
      },
      'sourceInSeconds': {
        'type': 'number',
        'description': 'New in-point within the source media.',
      },
    },
    'required': ['clipId'],
  };

  @override
  Future<String> run(Map<String, dynamic> args) async {
    final clipId = args['clipId'];
    if (clipId is! String || clipId.isEmpty) {
      throw ArgumentError('clipId is required.');
    }

    final clip = c.doc.clipById(clipId);
    if (clip == null) throw ArgumentError('No clip with id "$clipId".');

    final start = _seconds(args['startSeconds']);
    final duration = _seconds(args['durationSeconds']);
    final sourceIn = _seconds(args['sourceInSeconds']);
    if (start == null && duration == null && sourceIn == null) {
      throw ArgumentError(
        'Nothing to change: give at least one of startSeconds, '
        'durationSeconds or sourceInSeconds.',
      );
    }

    // Model output is never trusted for geometry (AI-16). Everything below is
    // clamped before it reaches the document, and the document's own
    // invariants get the final say on load and on every mutation.
    // Text clips carry an empty mediaId and have no source to clamp against.
    final media = clip.mediaId.isEmpty ? null : c.doc.assetById(clip.mediaId);
    final mediaSeconds = media?.duration.seconds;

    var newStart = start ?? clip.start.seconds;
    var newSourceIn = sourceIn ?? clip.sourceIn.seconds;
    var newDuration = duration ?? clip.duration.seconds;

    if (newStart < 0) newStart = 0;
    if (newSourceIn < 0) newSourceIn = 0;

    // A clip must last at least one frame, or it is not a clip.
    final oneFrame =
        1 / (c.doc.settings.fpsValue == 0 ? 30 : c.doc.settings.fpsValue);
    if (newDuration < oneFrame) newDuration = oneFrame;

    if (mediaSeconds != null && mediaSeconds > 0) {
      if (newSourceIn > mediaSeconds - oneFrame) {
        newSourceIn = mediaSeconds - oneFrame;
      }
      final available = mediaSeconds - newSourceIn;
      if (newDuration > available) newDuration = available;
    }

    final notes = <String>[];
    if (start != null && (start - newStart).abs() > 1e-6) {
      notes.add('start clamped to $newStart s');
    }
    if (duration != null && (duration - newDuration).abs() > 1e-6) {
      notes.add('duration clamped to $newDuration s');
    }
    if (sourceIn != null && (sourceIn - newSourceIn).abs() > 1e-6) {
      notes.add('source in-point clamped to $newSourceIn s');
    }

    c.runEdit('Set clip range', (tx) {
      tx.clip(clipId);
      final target = c.doc.clipById(clipId);
      if (target == null) return;
      target.start = Rt.fromSeconds(newStart);
      target.duration = Rt.fromSeconds(newDuration);
      target.sourceIn = Rt.fromSeconds(newSourceIn);
    });

    return encodeToolResult({
      'ok': true,
      'clipId': clipId,
      'startSeconds': newStart,
      'durationSeconds': newDuration,
      'sourceInSeconds': newSourceIn,
      if (notes.isNotEmpty) 'adjustments': notes,
    });
  }

  double? _seconds(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }
}
