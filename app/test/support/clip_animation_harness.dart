import 'package:flutter/foundation.dart';

import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/application/timeline_edits.dart';
import 'package:crazycut_app/modules/project/domain/param_value.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';

class ClipAnimationEdits extends ChangeNotifier with TimelineEdits {
  ClipAnimationEdits(this.doc);

  @override
  final ProjectDoc doc;

  @override
  Rt playhead = Rt.zero();

  @override
  double get fps => doc.settings.fpsValue;

  @override
  void markDirty() {}
}

Rt seconds(double value) => Rt.fromSeconds(value);

(ClipAnimationEdits, Clip) clipAnimationHarness({
  double duration = 6,
  String type = 'image',
}) {
  final doc = ProjectDoc.empty('Test', width: 1920, height: 1080, fps: 30);
  doc.media.add(
    MediaAsset(
      id: 'img',
      name: 'photo.png',
      path: '/tmp/photo.png',
      type: type,
      duration: seconds(duration),
      hasAudio: false,
      width: 1000,
      height: 1000,
    ),
  );
  final edits = ClipAnimationEdits(doc);
  final clip = Clip(
    id: 'c1',
    trackId: doc.videoTrack()!.id,
    mediaId: 'img',
    label: 'photo',
    start: seconds(2),
    duration: seconds(duration),
    sourceIn: Rt.zero(),
  );
  doc.clips.add(clip);
  return (edits, clip);
}

List<Map<String, dynamic>> keysOf(ParamValue value) => value.keyframes;

double evaluateAt(ParamValue value, double time) {
  final result = value.evaluate(seconds(time));
  return result is num ? result.toDouble() : double.nan;
}

Map<String, dynamic>? effectOf(Clip clip, String type) =>
    clip.effects
        .whereType<Map<String, dynamic>>()
        .where((effect) => effect['type'] == type)
        .firstOrNull;
