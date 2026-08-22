import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/param_value.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/text_content.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/timeline_edits.dart';

/// Minimal host for the mixin: no engine, no autosave, just the document.
class Edits extends ChangeNotifier with TimelineEdits {
  Edits(this.doc);

  @override
  final ProjectDoc doc;

  @override
  Rt playhead = Rt.zero();

  @override
  double get fps => doc.settings.fpsValue;

  @override
  void markDirty() {}
}

Rt s(double seconds) => Rt.fromSeconds(seconds);

(Edits, Clip) harness({double duration = 6, String type = 'image'}) {
  final doc = ProjectDoc.empty('Test', width: 1920, height: 1080, fps: 30);
  doc.media.add(
    MediaAsset(
      id: 'img',
      name: 'photo.png',
      path: '/tmp/photo.png',
      type: type,
      duration: s(duration),
      hasAudio: false,
      width: 1000,
      height: 1000,
    ),
  );
  final e = Edits(doc);
  final clip = Clip(
    id: 'c1',
    trackId: doc.videoTrack()!.id,
    mediaId: 'img',
    label: 'photo',
    start: s(2),
    duration: s(duration),
    sourceIn: Rt.zero(),
  );
  doc.clips.add(clip);
  return (e, clip);
}

List<Map<String, dynamic>> keysOf(ParamValue pv) => pv.keyframes;

double evalAt(ParamValue pv, double seconds) {
  final v = pv.evaluate(s(seconds));
  return v is num ? v.toDouble() : double.nan;
}

Map<String, dynamic>? fxOf(Clip clip, String type) =>
    clip.effects
        .whereType<Map<String, dynamic>>()
        .where((e) => e['type'] == type)
        .firstOrNull;

void main() {
  group('visual clip coverage', () {
    test('video clips have the same explicit entry and leave animation', () {
      final (e, clip) = harness(type: 'video');

      e.setClipEntryLeave(clip.id, entry: 'slideLeft', leave: 'fade');

      expect(e.clipAnimationPreset(clip, 'entry'), 'slideLeft');
      expect(e.clipAnimationPreset(clip, 'leave'), 'fade');
      expect(clip.extra['clipAnim'], isA<Map<String, dynamic>>());
      expect(clip.extra['imageAnim'], isNull);
      expect(evalAt(clip.transform!.x, 0), greaterThan(0));
      expect(evalAt(clip.transform!.opacity, 6), 0);

      e.clearClipAnimation(clip.id);
      expect(e.clipAnimationSpec(clip), isNull);
      expect(clip.transform!.x.animated, isFalse);
      expect(clip.transform!.opacity.animated, isFalse);
    });

    test('audio-only clips do not receive visual edge animation', () {
      final (e, clip) = harness(type: 'audio');

      e.setClipEntryExit(clip.id, appear: 'fade');

      expect(clip.transform, isNull);
      expect(e.clipAnimationSpec(clip), isNull);
    });

    test('text clips switch cleanly between presets and edge animation', () {
      final (e, clip) = harness();
      clip.text = TextContent(content: 'Lower third');
      e.applyTextPreset(clip.id, 'pop');

      e.setClipEntryLeave(clip.id, entry: 'fade', leave: 'slideLeft');

      expect(clip.text!.animation, isEmpty);
      expect(e.clipAnimationPreset(clip, 'entry'), 'fade');
      expect(e.clipAnimationPreset(clip, 'leave'), 'slideLeft');

      e.applyTextPreset(clip.id, 'slideUp');

      expect(e.clipAnimationSpec(clip), isNull);
      expect(clip.text!.animation, 'slideUp');
      expect(evalAt(clip.transform!.y, 0), -120);
    });
  });

  group('appear / disappear', () {
    test('fade in ramps opacity from zero to the resting value', () {
      final (e, clip) = harness();
      e.setImageEntryExit(clip.id, appear: 'fade');

      final opacity = clip.transform!.opacity;
      expect(opacity.animated, isTrue);
      expect(evalAt(opacity, 0), 0);
      expect(evalAt(opacity, 0.4), 100);
      // The rest of the clip stays fully opaque — no exit was asked for.
      expect(evalAt(opacity, 6), 100);
    });

    test('fade out ramps opacity back to zero at the tail only', () {
      final (e, clip) = harness();
      e.setImageEntryExit(clip.id, disappear: 'fade');

      final opacity = clip.transform!.opacity;
      expect(evalAt(opacity, 0), 100);
      expect(evalAt(opacity, 5.6), 100);
      expect(evalAt(opacity, 6), 0);
    });

    test('pop overshoots past the resting scale before settling', () {
      final (e, clip) = harness();
      e.setImageEntryExit(clip.id, appear: 'pop');

      final scale = clip.transform!.scale;
      expect(evalAt(scale, 0), lessThan(100));
      expect(evalAt(scale, 0.3), greaterThan(100));
      expect(evalAt(scale, 0.4), closeTo(100, 1e-6));
    });

    test('slide starts off the resting position and lands on it', () {
      final (e, clip) = harness();
      e.setImageEntryExit(clip.id, appear: 'slideLeft');

      final x = clip.transform!.x;
      // Travels leftwards, so it enters from the right of centre.
      expect(evalAt(x, 0), 1920 * 0.25);
      expect(evalAt(x, 0.4), 0);
    });

    test('blur adds a keyed gaussianBlur that resolves to zero radius', () {
      final (e, clip) = harness();
      e.setImageEntryExit(clip.id, appear: 'blur');

      final fx = fxOf(clip, 'gaussianBlur');
      expect(fx, isNotNull);
      final radius = ParamValue.from(fx!['params']['radius']);
      expect(evalAt(radius, 0), 24);
      expect(evalAt(radius, 0.4), 0);
      expect(evalAt(radius, 6), 0);
    });

    test('wipe adds a keyed crop on the matching side', () {
      final (e, clip) = harness();
      e.setImageEntryExit(clip.id, appear: 'wipeRight');

      final fx = fxOf(clip, 'crop');
      expect(fx, isNotNull);
      final right = ParamValue.from(fx!['params']['right']);
      expect(evalAt(right, 0), 100);
      expect(evalAt(right, 0.4), 0);
    });

    test('a custom duration stretches the animation window', () {
      final (e, clip) = harness();
      e.setImageEntryExit(clip.id, appear: 'fade', seconds: 1.5);

      expect(evalAt(clip.transform!.opacity, 0.4), lessThan(100));
      expect(evalAt(clip.transform!.opacity, 1.5), 100);
    });

    test('neither side may exceed half the clip', () {
      final (e, clip) = harness(duration: 1);
      e.setImageEntryExit(clip.id, appear: 'fade', seconds: 5);

      expect(evalAt(clip.transform!.opacity, 0.5), 100);
    });
  });

  group('composition', () {
    test('in and out coexist on one opacity curve', () {
      final (e, clip) = harness();
      e.setImageEntryExit(clip.id, appear: 'fade', disappear: 'fade');

      final opacity = clip.transform!.opacity;
      expect(evalAt(opacity, 0), 0);
      expect(evalAt(opacity, 3), 100);
      expect(evalAt(opacity, 6), 0);
    });

    test('an entry lands on the Ken Burns curve rather than on the base', () {
      final (e, clip) = harness();
      e.applyImagePreset(clip.id, 'zoomIn');
      e.setImageEntryExit(clip.id, appear: 'pop');

      final scale = clip.transform!.scale;
      // zoomIn runs 100 -> 115 across the clip, so the pop must settle onto
      // the value the move wants at 0.4s, not back onto a flat 100.
      final landing = evalAt(scale, 0.4);
      expect(landing, greaterThan(100));
      expect(landing, lessThan(115));
      expect(evalAt(scale, 6), closeTo(115, 1e-6));
    });

    test('blur in and wipe out share one clip without fighting', () {
      final (e, clip) = harness();
      e.setImageEntryExit(clip.id, appear: 'blur', disappear: 'wipeLeft');

      expect(fxOf(clip, 'gaussianBlur'), isNotNull);
      final crop = ParamValue.from(fxOf(clip, 'crop')!['params']['left']);
      expect(evalAt(crop, 0), 0);
      expect(evalAt(crop, 6), 100);
    });
  });

  group('rebuilding', () {
    test('is idempotent — reapplying the same preset changes nothing', () {
      final (e, clip) = harness();
      e.setImageEntryExit(clip.id, appear: 'blur');
      final first = clip.transform!.opacity.toJson().toString();
      final fxCount = clip.effects.length;

      e.setImageEntryExit(clip.id, appear: 'blur');

      expect(clip.transform!.opacity.toJson().toString(), first);
      expect(clip.effects, hasLength(fxCount));
    });

    test('switching preset leaves no stale managed effect behind', () {
      final (e, clip) = harness();
      e.setImageEntryExit(clip.id, appear: 'blur');
      expect(clip.effects, hasLength(1));

      e.setImageEntryExit(clip.id, appear: 'wipeLeft');

      expect(fxOf(clip, 'gaussianBlur'), isNull);
      expect(clip.effects, hasLength(1));
    });

    test('turning a side off removes its keys', () {
      final (e, clip) = harness();
      e.setImageEntryExit(clip.id, appear: 'fade', disappear: 'fade');
      e.setImageEntryExit(clip.id, appear: '');

      expect(evalAt(clip.transform!.opacity, 0), 100);
      expect(evalAt(clip.transform!.opacity, 6), 0);
    });

    test('user effects are never touched by a rebuild', () {
      final (e, clip) = harness();
      final userFx = e.addEffect(clip.id, 'vignette');
      e.setImageEntryExit(clip.id, appear: 'blur');
      e.setImageEntryExit(clip.id, appear: 'wipeUp');

      expect(
        clip.effects.whereType<Map>().map((f) => f['id']),
        contains(userFx),
      );
    });

    test('a rebasing edit moves the resting pose instead of keying it', () {
      final (e, clip) = harness();
      e.setImageEntryExit(clip.id, appear: 'slideLeft');
      e.playhead = s(4); // mid-clip, where a raw drag would drop a key

      e.setTransformParam(clip.id, 'x', 300, rebase: true);

      final x = clip.transform!.x;
      expect(evalAt(x, 0.4), 300, reason: 'the slide now rests at the new x');
      expect(evalAt(x, 6), 300);
      expect(keysOf(x), hasLength(2));
    });
  });

  group('clearing', () {
    test('drops keys, managed effects and the spec', () {
      final (e, clip) = harness();
      e.applyImagePreset(clip.id, 'panLeft');
      e.setImageEntryExit(clip.id, appear: 'blur', disappear: 'fade');

      e.clearImageAnimation(clip.id);

      expect(clip.transform!.opacity.animated, isFalse);
      expect(clip.transform!.x.animated, isFalse);
      expect(clip.transform!.scale.animated, isFalse);
      expect(clip.effects, isEmpty);
      expect(e.imageAnimSpec(clip), isNull);
    });

    test('leaves the clip at its resting pose, not at the last keyframe', () {
      final (e, clip) = harness();
      e.setTransformParam(clip.id, 'x', 120);
      e.setImageEntryExit(clip.id, appear: 'slideLeft');

      e.clearImageAnimation(clip.id);

      expect(clip.transform!.x.static, 120);
    });
  });

  test('the generic spec survives a project round-trip', () {
    final (e, clip) = harness();
    e.setClipEntryLeave(clip.id, entry: 'pop', leave: 'fade');

    final reloaded = ProjectDoc.decode(e.doc.encode(touchModified: false));
    final restored = reloaded.clipById('c1')!;

    expect(e.clipAnimationPreset(restored, 'entry'), 'pop');
    expect(e.clipAnimationPreset(restored, 'leave'), 'fade');
    expect(restored.extra['clipAnim'], isNotNull);
    expect(restored.extra['imageAnim'], isNull);
  });

  test('legacy image animation data migrates to explicit entry and leave', () {
    final (e, clip) = harness();
    final legacy = <String, dynamic>{
      'motion': null,
      'in': {'type': 'fade', 'seconds': 0.4},
      'out': {'type': 'pop', 'seconds': 0.6},
      'base': {'x': 0, 'y': 0, 'scale': 100, 'opacity': 100},
      'fx': <String>[],
    };
    final json = e.doc.encode(touchModified: false);
    final decodedJson = jsonDecode(json) as Map<String, dynamic>;
    (decodedJson['clips'] as List<dynamic>)[0]['imageAnim'] = legacy;
    final decoded = ProjectDoc.decode(jsonEncode(decodedJson));
    final restored = decoded.clipById(clip.id)!;
    final migrated = Edits(decoded).clipAnimationSpec(restored)!;

    expect(migrated['entry'], isNotNull);
    expect(migrated['leave'], isNotNull);
    expect(migrated['in'], isNull);
    expect(migrated['out'], isNull);
    expect(restored.extra['clipAnim'], isNotNull);
    expect(restored.extra['imageAnim'], isNull);
  });

  test('the resting pose survives a rebuild on an already-animated clip', () {
    final (e, clip) = harness();
    e.setTransformParam(clip.id, 'scale', 40);
    e.setImageEntryExit(clip.id, appear: 'pop');
    expect(e.imageAnimResting(clip)['scale'], 40);

    // A rebuild that has to re-derive the pose (a project whose spec was lost,
    // an older file) must read it from the middle of the clip. Reading t=0 —
    // where pop parks its 0.7x start value — shrank the image by 30% every time
    // the animation was touched.
    clip.extra.remove('imageAnim');
    e.setImageEntryExit(clip.id, appear: 'pop');
    expect(e.imageAnimResting(clip)['scale'], closeTo(40, 0.001));
    expect(evalAt(clip.transformOrDefault.scale, 3), closeTo(40, 0.001));
  });
}
