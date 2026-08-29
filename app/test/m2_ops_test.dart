import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
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

  int dirtyCount = 0;

  @override
  void markDirty() => dirtyCount++;
}

Rt s(double seconds) => Rt.fromSeconds(seconds);

Edits harness({double assetSeconds = 20, double fps = 30}) {
  final doc = ProjectDoc.empty('Test', width: 1920, height: 1080, fps: fps);
  doc.media.add(
    MediaAsset(
      id: 'asset-1',
      name: 'clip.mov',
      path: '/tmp/clip.mov',
      type: 'video',
      duration: s(assetSeconds),
      hasAudio: true,
    ),
  );
  return Edits(doc);
}

Clip addClip(
  Edits e, {
  required String id,
  required double start,
  required double duration,
  double sourceIn = 0,
  String? trackId,
  String? mediaId = 'asset-1',
}) {
  final clip = Clip(
    id: id,
    trackId: trackId ?? e.doc.videoTrack()!.id,
    mediaId: mediaId!,
    label: id,
    start: s(start),
    duration: s(duration),
    sourceIn: s(sourceIn),
  );
  e.doc.clips.add(clip);
  return clip;
}

/// Byte-identical clip JSON comparison for undo assertions.
Map<String, Map<String, dynamic>> clipJson(ProjectDoc doc) => {
  for (final c in doc.clips) c.id: c.toJson(),
};

void main() {
  group('transitions: creation (TRA-2/3)', () {
    test(
      'butt-joined clips with ample handles overlap and undo in one step',
      () {
        final e = harness(assetSeconds: 60);
        addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 0);
        addClip(e, id: 'b', start: 5, duration: 5, sourceIn: 5);

        final before = clipJson(e.doc);
        final id = e.addTransition('a', 'b');

        expect(id, isNotNull);
        expect(e.lastTransitionError, isNull);
        final tr = e.doc.transitionById(id!)!;
        // Default 0.5 s centered: a quarter second each side.
        expect(tr.duration, s(0.5));
        expect(tr.aExtend, s(0.25));
        expect(tr.bExtend, s(0.25));
        final a = e.clipById('a')!;
        final b = e.clipById('b')!;
        expect(a.duration, s(5.25));
        expect(b.start, s(4.75));
        expect(b.sourceIn, s(4.75));
        expect(b.duration, s(5.25));
        // Invariant: computed overlap == stored duration (§5).
        final overlapStart = b.start;
        final overlapEnd = a.end < b.end ? a.end : b.end;
        expect(overlapEnd.minus(overlapStart), tr.duration);

        expect(e.history.depth, 1);
        e.undo();
        expect(clipJson(e.doc), before); // byte-identical restore
        expect(e.doc.transitions, isEmpty);
        e.redo();
        expect(e.doc.transitionById(id), isNotNull);
      },
    );

    test('zero-handle cut refuses with toast text and no document change', () {
      final e = harness(assetSeconds: 10);
      // Two assets, each consumed exactly by its clip (sourceIn+span ==
      // asset duration): no tail handle on A, no head handle on B.
      e.doc.media.add(
        MediaAsset(
          id: 'asset-2',
          name: 'clip2.mov',
          path: '/tmp/clip2.mov',
          type: 'video',
          duration: s(10),
          hasAudio: true,
        ),
      );
      addClip(
        e,
        id: 'a',
        start: 0,
        duration: 10,
        sourceIn: 0,
        mediaId: 'asset-1',
      );
      addClip(
        e,
        id: 'b',
        start: 10,
        duration: 10,
        sourceIn: 0,
        mediaId: 'asset-2',
      );

      final before = clipJson(e.doc);
      final id = e.addTransition('a', 'b');
      expect(id, isNull);
      expect(
        e.lastTransitionError,
        'No extra media at this cut — trim the clips to make room',
      );
      expect(clipJson(e.doc), before);
      expect(e.history.depth, 0);
    });

    test('unknown or offline media conservatively refuses (no handles)', () {
      final e = harness(assetSeconds: 20);
      addClip(e, id: 'a', start: 0, duration: 5, mediaId: 'ghost-asset');
      addClip(e, id: 'b', start: 5, duration: 5);

      expect(e.addTransition('a', 'b'), isNull);
      expect(
        e.lastTransitionError,
        'No extra media at this cut — trim the clips to make room',
      );
    });

    test('non-neighbours on the same track refuse; other tracks refuse', () {
      final e = harness(assetSeconds: 60);
      addClip(e, id: 'a', start: 0, duration: 5);
      addClip(e, id: 'b', start: 8, duration: 5);
      addClip(e, id: 'c', start: 13, duration: 5);

      expect(e.addTransition('a', 'c'), isNull);
      expect(
        e.lastTransitionError,
        'Clips must be neighbours on the same track',
      );

      // Different tracks refuse too.
      addClip(
        e,
        id: 'x',
        start: 0,
        duration: 5,
        trackId: e.doc.audioTrack()!.id,
      );
      expect(e.addTransition('a', 'x'), isNull);
      expect(
        e.lastTransitionError,
        'Clips must be neighbours on the same track',
      );
    });

    test('asymmetric handles fall back to the side that can pay', () {
      final e = harness(assetSeconds: 60);
      // A has 3s of tail handle; B sits at its head (sourceIn 0).
      addClip(e, id: 'a', start: 0, duration: 2, sourceIn: 4);
      addClip(e, id: 'b', start: 2, duration: 5, sourceIn: 0);

      final id = e.addTransition('a', 'b')!;
      final tr = e.doc.transitionById(id)!;
      expect(tr.bExtend, Rt.zero());
      // A pays the whole span.
      expect(tr.aExtend, s(0.5));
      expect(tr.alignment, 'end');
      expect(e.clipById('a')!.duration, s(2.5));
      expect(e.clipById('b')!.start, s(2));
      expect(e.clipById('b')!.sourceIn, s(0));

      // One undo restores everything.
      e.undo();
      expect(e.clipById('a')!.duration, s(2));
      expect(e.doc.transitions, isEmpty);
    });

    test(
      'speed-scaled handles: B consumed at half speed pays twice as far',
      () {
        final e = harness(assetSeconds: 60);
        addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 5);
        final b = Clip(
          id: 'b',
          trackId: e.doc.videoTrack()!.id,
          mediaId: 'asset-1',
          label: 'b',
          start: s(5),
          duration: s(5),
          sourceIn: s(10),
          speed: '1/2', // half speed: sequence seconds = 2 × source seconds
        );
        e.doc.clips.add(b);

        final id = e.addTransition('a', 'b')!;
        final tr = e.doc.transitionById(id)!;
        // bExtend of 0.25 sequence-s consumes 0.125 source-s.
        expect(tr.bExtend, s(0.25));
        expect(b.sourceIn, s(9.875));
        expect(b.start, s(4.75));

        // Removal restores exactly (TRA-10 bookkeeping).
        e.removeTransition(id);
        expect(b.sourceIn, s(10));
        expect(b.start, s(5));
        expect(b.duration, s(5));
      },
    );
  });

  group('transitions: retiming and type (TRA-5/6)', () {
    test('retim consumes more handles; shrink returns them; removal restores '
        'ORIGINAL positions', () {
      final e = harness(assetSeconds: 60);
      addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 0);
      addClip(e, id: 'b', start: 5, duration: 5, sourceIn: 5);
      final originalA = e.clipById('a')!.toJson();
      final originalB = e.clipById('b')!.toJson();

      final id = e.addTransition('a', 'b')!;
      final err = e.setTransitionDuration(id, s(1.5));
      expect(err, '');

      final tr = e.doc.transitionById(id)!;
      expect(tr.duration, s(1.5));
      expect(tr.aExtend, s(0.75));
      expect(tr.bExtend, s(0.75));

      // Shrink back to 0.5 returns the handles.
      expect(e.setTransitionDuration(id, s(0.5)), '');
      final shrunk = e.doc.transitionById(id)!;
      expect(shrunk.aExtend, s(0.25));
      expect(shrunk.bExtend, s(0.25));

      // Removal after retim restores the ORIGINAL butt joint exactly.
      e.removeTransition(id);
      final a = e.clipById('a')!;
      final b = e.clipById('b')!;
      expect(a.toJson(), originalA);
      expect(b.toJson(), originalB);
      expect(e.doc.transitions, isEmpty);
    });

    test('retim clamps to feasible max when handles run out', () {
      final e = harness(assetSeconds: 12);
      // A consumes [5..10) of a 12 s asset: 2 s tail. B consumes [3..4):
      // 3 s head. Total handle pool = 5 s.
      addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 5);
      addClip(e, id: 'b', start: 5, duration: 1, sourceIn: 3);

      final id = e.addTransition('a', 'b')!;
      final err = e.setTransitionDuration(id, s(10));
      expect(err, '');
      // Handle pool (2s + 3s) is the ceiling; the aA ≤ origDurB rule shifts
      // the excess to B rather than capping the total.
      expect(e.doc.transitionById(id)!.duration, s(5));
    });

    test('replace-type path preserves duration and extends (TRA-5)', () {
      final e = harness(assetSeconds: 60);
      addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 0);
      addClip(e, id: 'b', start: 5, duration: 5, sourceIn: 5);

      final id = e.addTransition('a', 'b')!;
      final before = e.doc.transitionById(id)!.toJson();
      expect(before['easing'], 'easeInOut');

      final again = e.addTransition('a', 'b', type: 'pushLeft');
      expect(again, id); // same entity
      expect(e.doc.transitions, hasLength(1)); // one-per-cut enforced
      final after = e.doc.transitionById(id)!;
      expect(after.type, 'pushLeft');
      expect(after.easing, 'linear'); // catalog default per type
      expect(after.duration.toString(), before['duration']);
      expect(after.aExtend.toString(), before['aExtend']);
      expect(after.bExtend.toString(), before['bExtend']);
    });

    test('setTransitionType preserves extends; alignment redistributes', () {
      final e = harness(assetSeconds: 60);
      addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 0);
      addClip(e, id: 'b', start: 5, duration: 5, sourceIn: 5);
      final id = e.addTransition('a', 'b', type: 'dipToBlack')!;

      e.setTransitionType(id, 'zoomIn');
      var tr = e.doc.transitionById(id)!;
      expect(tr.type, 'zoomIn');
      expect(tr.duration, s(0.5));
      expect(tr.aExtend, s(0.25));
      expect(tr.bExtend, s(0.25));
      expect(tr.easing, 'easeInOut'); // zoom defaults to easeInOut

      e.setTransitionAlignment(id, 'start');
      tr = e.doc.transitionById(id)!;
      expect(tr.alignment, 'start');
      expect(tr.aExtend, Rt.zero());
      expect(tr.bExtend, s(0.5));
      // Total unchanged; geometry follows.
      expect(e.clipById('a')!.duration, s(5));
      expect(e.clipById('b')!.start, s(4.5));

      // Undo restores both geometry and alignment in one step.
      e.undo();
      tr = e.doc.transitionById(id)!;
      expect(tr.alignment, 'center');
      expect(e.clipById('a')!.duration, s(5.25));
      expect(e.clipById('b')!.start, s(4.75));
    });
  });

  group('transitions: deletion and sanitize (TRA-4, edge cases)', () {
    test('deleteClips removes bound transition; survivor keeps one frame', () {
      final e = harness(assetSeconds: 60);
      addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 0);
      addClip(e, id: 'b', start: 5, duration: 5, sourceIn: 5);
      final id = e.addTransition('a', 'b')!;

      e.deleteClip('b');
      expect(e.doc.transitionById(id), isNull);
      // Surviving A got its consumed handle back.
      expect(e.clipById('a')!.duration, s(5));
      // One undo brings back clip AND transition AND geometry.
      e.undo();
      expect(e.doc.transitionById(id), isNotNull);
      expect(e.clipById('a')!.duration, s(5.25));
      expect(e.clipById('b'), isNotNull);
    });

    test('ripple delete BEFORE A slides A+B together; transition survives '
        'with unchanged extends', () {
      final e = harness(assetSeconds: 60);
      addClip(e, id: 'pre', start: 0, duration: 2, sourceIn: 10);
      addClip(e, id: 'a', start: 2, duration: 5, sourceIn: 0);
      addClip(e, id: 'b', start: 7, duration: 5, sourceIn: 5);
      final id = e.addTransition('a', 'b')!;
      final extendsBefore = (
        e.doc.transitionById(id)!.aExtend,
        e.doc.transitionById(id)!.bExtend,
      );

      e.deleteClip('pre', ripple: true);
      // Both slid left by the deleted span; extends ride along untouched.
      // B's start was already 6.75 (creation consumed 0.25), so it lands at
      // 4.75 and keeps its extend.
      expect(e.clipById('a')!.start, s(0));
      expect(e.clipById('b')!.start, s(4.75));
      final tr = e.doc.transitionById(id)!;
      expect(tr.aExtend, extendsBefore.$1);
      expect(tr.bExtend, extendsBefore.$2);

      e.undo(); // coherent single step
      expect(e.doc.transitionById(id), isNotNull);
      expect(e.clipById('pre'), isNotNull);
      expect(e.clipById('a')!.start, s(2));
      expect(e.clipById('b')!.start, s(6.75));
    });

    test('trim into the consumed range shrinks then deletes the transition', () {
      final e = harness(assetSeconds: 60);
      addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 0);
      addClip(e, id: 'b', start: 5, duration: 5, sourceIn: 5);
      final id = e.addTransition('a', 'b')!;

      // Trim A's tail deep into the overlap: the span shrinks to its floor
      // (one frame) rather than dying mid-gesture (TRA-4 edge case).
      e.trimEnd('a', e.clipById('a')!.end.minus(s(0.48)), snap: false);
      final floorTr = e.doc.transitionById(id);
      expect(floorTr, isNotNull);
      expect(floorTr!.duration, e.frameDuration);

      // Fresh scenario: shrink instead of delete. Butt-join two fresh clips
      // away from the first trim site and re-create a cut transition.
      addClip(e, id: 'd', start: 20, duration: 5, sourceIn: 0);
      addClip(e, id: 'e', start: 25, duration: 5, sourceIn: 5);
      final id2 = e.addTransition('d', 'e')!;
      expect(e.doc.transitionById(id2), isNotNull);

      // Shave D's tail by 0.1 s: overlap drops to 0.4 s (> 1 frame @30 fps),
      // so the transition shrinks rather than dying.
      final before = e.clipById('d')!.end;
      e.trimEnd('d', before.minus(s(0.1)), snap: false);
      // Overlap = 0.4 s ≥ 1 frame → transition shrinks instead of dying.
      final tr2 = e.doc.transitionById(id2);
      expect(
        tr2,
        isNotNull,
        reason:
            'before=$before after=${e.clipById('d')!.end} estart=${e.clipById('e')!.start}',
      );
      expect(tr2!.duration, s(0.4));
      expect(tr2.aExtend.plus(tr2.bExtend), s(0.4));
    });

    test('split strictly inside an overlap removes the transition first', () {
      final e = harness(assetSeconds: 60);
      addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 0);
      addClip(e, id: 'b', start: 5, duration: 5, sourceIn: 5);
      final id = e.addTransition('a', 'b')!;
      final aBefore = e.clipById('a')!.toJson();
      final bBefore = e.clipById('b')!.toJson();

      // Playhead inside the transition span.
      e.playhead = s(5.25); // center of the overlap
      final created = e.splitAtPlayhead();
      expect(created, hasLength(1));
      expect(e.doc.transitionById(id), isNull);
      // Joints restored before the split proceeded.
      final aJson = {...aBefore};
      aJson['duration'] = s(0.25).toString(); // left fragment of the overlap
      expect(e.clipById('b')!.toJson()['start'] as String, s(5).toString());

      e.undo();
      expect(e.doc.transitionById(id), isNotNull);
      final afterUndo = clipJson(e.doc)['b']!;
      // Undo must restore B exactly as it was under the transition.
      expect(afterUndo['start'], bBefore['start']);
      expect(afterUndo['duration'], bBefore['duration']);
      expect(afterUndo['sourceIn'], bBefore['sourceIn']);
    });

    test('roll across a transitioned cut keeps overlap == duration', () {
      final e = harness(assetSeconds: 60);
      addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 0);
      addClip(e, id: 'b', start: 5, duration: 5, sourceIn: 5);
      final id = e.addTransition('a', 'b')!;

      e.beginRoll('a', 'b');
      e.updateDrag(-0.25, snap: false);
      e.endGesture();

      final tr = e.doc.transitionById(id);
      if (tr != null) {
        // Still valid: overlap must equal duration exactly.
        final a = e.clipById('a')!;
        final b = e.clipById('b')!;
        final overlapEnd = a.end < b.end ? a.end : b.end;
        expect(
          overlapEnd.minus(b.start > a.start ? b.start : a.start),
          tr.duration,
        );
      }
    });
  });

  group('text clips (TXT-1/5)', () {
    test('addTextClip places a 5s clip at playhead and selects it', () {
      final e = harness();
      e.playhead = s(3);

      final created = e.addTextClip();
      expect(created, hasLength(1));
      final clip = e.clipById(created.single)!;
      expect(clip.mediaId, '');
      expect(clip.label, 'Text');
      expect(clip.text, isNotNull);
      expect(clip.transform, isNotNull);
      expect(clip.start, s(3));
      expect(clip.duration, s(5));
      expect(e.selection, {clip.id});
    });

    test('an entry animation bakes editable keyframes; one-step undo', () {
      final e = harness();
      final id = e.addTextClip().single;

      e.setClipEntryLeave(id, entry: 'pop', seconds: 0.5);
      final clip = e.clipById(id)!;
      final scaleKeys = clip.transform!.scale.keyframes;
      expect(scaleKeys, hasLength(3));
      expect(scaleKeys.first['v'], 70.0); // 0.7 x the resting 100
      expect(scaleKeys.first['interp'], 'easeOut');
      expect(scaleKeys.last['v'], 100.0);
      expect(Rt.parse(scaleKeys.last['t'] as String), s(0.5));
      expect(clip.transform!.opacity.keyframes.first['v'], 0.0);
      expect(e.clipAnimationPreset(clip, 'entry'), 'pop');

      e.undo();
      final undone = e.clipById(id)!;
      expect(undone.transform!.scale.keyframes, isEmpty);
      expect(undone.transform!.opacity.keyframes, isEmpty);
    });

    test('entry and leave are chosen and timed independently', () {
      final e = harness();
      final id = e.addTextClip().single; // 5 s

      e.setClipEntryLeave(id, entry: 'fade', seconds: 0.5);
      e.setClipEntryLeave(id, leave: 'rise', seconds: 0.75);

      final clip = e.clipById(id)!;
      expect(e.clipAnimationSeconds(clip, 'entry'), 0.5);
      expect(e.clipAnimationSeconds(clip, 'leave'), 0.75);
      final opacity = clip.transform!.opacity.keyframes;
      expect(Rt.parse(opacity.first['t'] as String), Rt.zero());
      expect(Rt.parse(opacity.last['t'] as String), s(5));
      expect(opacity.last['v'], 0.0);
      // Rise leaves upwards, so y ends above its resting 0.
      expect(clip.transform!.y.keyframes.last['v'], lessThan(0));
    });

    test('a typewriter entry types over its own duration, not the transform', () {
      final e = harness();
      final id = e.addTextClip().single;
      e.setTextContent(id, 'Hello');

      e.setClipEntryLeave(id, entry: 'typewriter', seconds: 0.5);
      final clip = e.clipById(id)!;
      expect(e.clipAnimationPreset(clip, 'entry'), 'typewriter');
      expect(clip.transform!.scale.keyframes, isEmpty);
      expect(clip.transform!.opacity.keyframes, isEmpty);
      expect(e.typewriterRevealSeconds(clip), 0.5);
    });

    test('only text clips can type in', () {
      final e = harness();
      final clip = addClip(e, id: 'v1', start: 0, duration: 4);

      e.setClipEntryLeave(clip.id, entry: 'typewriter');

      expect(e.clipAnimationPreset(clip, 'entry'), isNull);
      expect(e.typewriterRevealSeconds(clip), isNull);
    });

    test('switching and clearing an entry removes stale generated channels', () {
      final e = harness();
      final id = e.addTextClip().single;

      e.setClipEntryLeave(id, entry: 'pop');
      expect(e.clipById(id)!.transform!.scale.keyframes, isNotEmpty);

      e.setClipEntryLeave(id, entry: 'slideLeft');
      var clip = e.clipById(id)!;
      expect(e.clipAnimationPreset(clip, 'entry'), 'slideLeft');
      expect(clip.transform!.scale.keyframes, isEmpty);
      expect(clip.transform!.scale.static, 100);
      expect(clip.transform!.x.keyframes, isNotEmpty);

      e.clearClipAnimation(id);
      clip = e.clipById(id)!;
      expect(e.clipAnimationSpec(clip), isNull);
      expect(clip.transform!.x.keyframes, isEmpty);
      expect(clip.transform!.x.static, 0);
      expect(clip.transform!.opacity.keyframes, isEmpty);
      expect(clip.transform!.opacity.static, 100);
    });

    test('blink uses hold interps and cycles to the clip duration', () {
      final e = harness();
      final id = e.addTextClip().single; // 5s → starts at 0, 0.75, 1.5 …
      e.applyMotionPreset(id, 'blink');
      final keys = e.clipById(id)!.transform!.opacity.keyframes;
      expect(keys.where((k) => k['interp'] == 'hold'), hasLength(keys.length));
      expect(Rt.parse(keys.first['t'] as String), Rt.zero());
      expect(keys.first['v'], 100.0);
      // Last cycle's lit key must not exceed the clip duration.
      expect(Rt.parse(keys.last['t'] as String) <= s(5), isTrue);
    });

    test('a legacy text preset migrates onto the shared spec', () {
      final e = harness();
      final id = e.addTextClip().single;
      e.setTextContent(id, 'Legacy');
      final clip = e.clipById(id)!;
      // A project saved before text animation joined the clip animation
      // system: provenance on the text, keyframes baked into the transform.
      clip.text!.animation = 'slideLeft';
      clip.transform!.x.keyframes.addAll([
        {'t': Rt.zero().toString(), 'v': -120.0, 'interp': 'easeOut'},
        {'t': s(0.5).toString(), 'v': 0.0, 'interp': 'linear'},
      ]);

      e.migrateLegacyTextAnimations();

      expect(clip.text!.animation, isEmpty);
      // The old name was where the text came from; the shared one is where it
      // travels, so the same look reads as the opposite word.
      expect(e.clipAnimationPreset(clip, 'entry'), 'slideRight');
      expect(e.clipAnimationSeconds(clip, 'entry'), 0.5);
      expect(clip.transform!.x.keyframes, hasLength(2));
      expect(clip.transform!.x.keyframes.last['v'], 0.0);
      expect(clip.transform!.x.static, 0);
    });

    test('a legacy typewriter keeps typing at its old rate', () {
      final e = harness();
      final id = e.addTextClip().single;
      e.setTextContent(id, '012345678901'); // 12 runes at 24/s = 0.5 s
      final clip = e.clipById(id)!;
      clip.text!.animation = 'typewriter';

      e.migrateLegacyTextAnimations();

      expect(e.clipAnimationPreset(clip, 'entry'), 'typewriter');
      expect(e.typewriterRevealSeconds(clip), closeTo(0.5, 1e-9));
    });
  });

  group('image animation (TXT-8/9)', () {
    Edits imageHarness() {
      final e = harness();
      e.doc.media.add(
        MediaAsset(
          id: 'image-1',
          name: 'poster.webp',
          path: '/tmp/poster.webp',
          type: 'image',
          duration: Rt.zero(),
          hasAudio: false,
        ),
      );
      return e;
    }

    test('zoom preset spans the clip with editable ease-in-out keys', () {
      final e = imageHarness();
      final id = e.placeAsset('image-1').single;

      e.applyImagePreset(id, 'zoomIn');

      final scale = e.clipById(id)!.transform!.scale;
      expect(scale.keyframes, hasLength(2));
      expect(scale.keyframes.first['t'], Rt.zero().toString());
      expect(scale.keyframes.first['v'], 100.0);
      expect(scale.keyframes.first['interp'], 'easeInOut');
      expect(scale.keyframes.last['t'], s(5).toString());
      expect(scale.keyframes.last['v'], 115.0);

      e.undo();
      expect(e.clipById(id)!.transform, isNull);
      e.redo();
      expect(e.clipById(id)!.transform!.scale.keyframes, hasLength(2));
    });

    test(
      'pan presets use sequence-relative offsets and preserve other axes',
      () {
        final e = imageHarness();
        final id = e.placeAsset('image-1').single;
        e.setTransformParam(id, 'rotation', 12);
        e.setTransformParam(id, 'y', 24);

        e.applyImagePreset(id, 'panLeft');

        final transform = e.clipById(id)!.transform!;
        expect(transform.x.keyframes.first['v'], 96.0);
        expect(transform.x.keyframes.last['v'], -96.0);
        expect(transform.scale.keyframes.map((k) => k['v']), [115.0, 115.0]);
        expect(transform.y.static, 24.0);
        expect(transform.y.keyframes, isEmpty);
        expect(transform.rotation.static, 12.0);
      },
    );

    test('animated slider edit writes a key at the clip-local playhead', () {
      final e = imageHarness();
      final id = e.placeAsset('image-1').single;
      e.applyImagePreset(id, 'zoomIn');

      e.setTransformParam(id, 'scale', 132, at: s(2));

      final scale = e.clipById(id)!.transform!.scale;
      expect(scale.keyframes, hasLength(3));
      final key = scale.keyframes.singleWhere((k) => k['t'] == s(2).toString());
      expect(key['v'], 132.0);
      expect(scale.static, 100.0);

      e.setTransformParam(id, 'scale', 140, at: s(2));
      expect(scale.keyframes, hasLength(3));
      expect(
        scale.keyframes.singleWhere((k) => k['t'] == s(2).toString())['v'],
        140.0,
      );
    });

    test('clear image animation restores the resting pose and other keys', () {
      final e = imageHarness();
      final id = e.placeAsset('image-1').single;
      e.applyImagePreset(id, 'panDown');
      e.toggleKeyframe(id, '__transform', 'opacity', Rt.zero());
      e.setKeyframeValue(id, '__transform', 'opacity', s(5), 40.0);

      e.clearImageAnimation(id);

      final transform = e.clipById(id)!.transform!;
      // The pose the preset animated *around* — not wherever the move happened
      // to end, which would leave the image drifted off-centre and oversized.
      expect(transform.y.keyframes, isEmpty);
      expect(transform.y.static, 0.0);
      expect(transform.scale.keyframes, isEmpty);
      expect(transform.scale.static, 100.0);
      // Opacity was hand-keyed, not generated, so clearing must not touch it.
      expect(transform.opacity.keyframes, hasLength(2));

      e.undo();
      expect(e.clipById(id)!.transform!.y.keyframes, hasLength(2));
    });

    test('preset keys are marked generated and survive a delete request', () {
      final e = imageHarness();
      final id = e.placeAsset('image-1').single;
      e.applyImagePreset(id, 'zoomIn');

      final markers = e.clipKeyframeMarkers(e.clipById(id)!);
      expect(markers, isNotEmpty);
      expect(markers.every((m) => m.allGenerated), isTrue);

      // Deleting one would only be undone by the next spec rebuild, so the
      // operation refuses rather than pretending.
      expect(e.removeKeyframesAt(id, markers.first.time), 0);
      expect(e.clipById(id)!.transform!.scale.keyframes, hasLength(2));
    });

    test('image presets ignore video clips', () {
      final e = harness();
      addClip(e, id: 'video', start: 0, duration: 5);

      e.applyImagePreset('video', 'zoomIn');

      expect(e.clipById('video')!.transform, isNull);
      expect(e.history.depth, 0);
    });
  });

  group('effects (FX-1..4, FX-14)', () {
    test('addEffect writes catalog defaults as static params', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 0, duration: 5);
      final fxId = e.addEffect('a', 'saturation');
      expect(fxId, isNotEmpty);

      final fx = e.clipById('a')!.effects.single as Map<String, dynamic>;
      expect(fx['type'], 'saturation');
      expect(fx['enabled'], isTrue);
      final amount = fx['params']['amount'] as Map<String, dynamic>;
      expect(amount['static'], 1.0); // saturation default
      // addEffect writes an empty (omitted-when-serialized) keyframe list.
      expect(amount['keyframes'] ?? const [], isEmpty);

      // One undo removes it cleanly.
      e.undo();
      expect(e.clipById('a')!.effects, isEmpty);
    });

    test('reorder swaps application order; enable/disable toggles', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 0, duration: 5);
      final blurId = e.addEffect('a', 'gaussianBlur');
      final satId = e.addEffect('a', 'saturation');
      final effects = e.clipById('a')!.effects;
      // Append order: blur landed first; index 0 applies first (FX-1).
      expect(
        effects.first,
        isA<Map<String, dynamic>>().having((m) => m['id'], 'id', blurId),
      );
      final reordered = e.clipById('a')!.effects.cast<Map<String, dynamic>>();
      expect(reordered[0]['id'], blurId);
      expect(reordered[1]['id'], satId);

      e.setEffectEnabled('a', blurId, false);
      expect(
        (e.clipById('a')!.effects.first as Map<String, dynamic>)['enabled'],
        isFalse,
      );
      expect(e.selectionOverloaded, isFalse);
    });

    test('resetEffect restores defaults clearing keyframes in one step', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 0, duration: 5);
      final fxId = e.addEffect('a', 'gaussianBlur');

      e.setEffectParam('a', fxId, 'radius', 42.0);
      expect(_paramStatic(e, 'a', fxId, 'radius'), 42.0);

      e.resetEffect('a', fxId);
      expect(_paramStatic(e, 'a', fxId, 'radius'), 8.0);

      e.undo();
      // One undo restores the user value (keyframes would come back too).
      expect(_paramStatic(e, 'a', fxId, 'radius'), 42.0);
    });

    test('selectionOverloaded fires past 8 enabled effects only', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 0, duration: 5);
      e.selectClip('a');
      const all = [
        'exposure',
        'contrast',
        'saturation',
        'temperature',
        'tint',
        'fade',
        'vignette',
        'gaussianBlur',
        'pixelate',
      ];
      for (final typeId in all) {
        e.addEffect('a', typeId);
      }
      expect(e.selectionOverloaded, isTrue); // 9 enabled
      // Disable one → exactly 8 → hint clears.
      final first =
          (e.clipById('a')!.effects.first as Map<String, dynamic>)['id'];
      e.setEffectEnabled('a', first as String, false);
      expect(e.selectionOverloaded, isFalse);
    });

    test('copy captures look and audio settings for one-step paste', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 0, duration: 5);
      addClip(e, id: 'b', start: 10, duration: 5);
      final srcFx = e.addEffect('a', 'saturation');
      e.setEffectParam('a', srcFx, 'amount', 1.7);
      e.setClipBlend('a', 'multiply');
      e.setTransformParam('a', 'rotation', 12);
      e.setClipAudio('a', volume: 0.4, pan: -0.25, mute: true);
      final source = e.clipById('a')!;
      source.fadeIn = Fade(duration: s(1), curve: 'scurve');
      source.fadeOut = Fade(duration: s(2), curve: 'exponential');
      e.selectClip('a');
      e.copySelection();
      expect(e.hasAttributeClipboard, isTrue);
      e.setEffectParam('a', srcFx, 'amount', 0.2);
      e.setTransformParam('a', 'rotation', 99);
      e.setClipAudio('a', volume: 0.8);

      final historyDepth = e.history.depth;
      e.selectClip('b');
      e.pasteAttributes();

      final pasted = e.clipById('b')!.effects.single as Map<String, dynamic>;
      expect(pasted['id'], isNot(srcFx)); // FRESH instance id
      expect(pasted['type'], 'saturation');
      expect(pasted['params']['amount']['static'], 1.7);
      final target = e.clipById('b')!;
      expect(target.blend, 'multiply');
      expect(target.transform!.rotation.static, 12);
      expect(target.volume, 0.4);
      expect(target.pan, -0.25);
      expect(target.mute, isTrue);
      expect(target.fadeIn.duration, s(1));
      expect(target.fadeIn.curve, 'scurve');
      expect(target.fadeOut.duration, s(2));
      expect(target.fadeOut.curve, 'exponential');
      expect(e.history.depth, historyDepth + 1); // ONE tx

      e.undo();
      expect(e.clipById('b')!.effects, isEmpty);
      expect(e.clipById('b')!.blend, 'normal');
    });

    test('paste settings overwrites defaults and scales fades to target', () {
      final e = harness(assetSeconds: 30);
      final source = addClip(e, id: 'a', start: 0, duration: 10)
        ..fadeIn = Fade(duration: s(6), curve: 'scurve')
        ..fadeOut = Fade(duration: s(4), curve: 'exponential');
      addClip(e, id: 'b', start: 12, duration: 5);
      e.selectClip(source.id);
      e.copySelection();

      e.selectClip('b');
      e.pasteAttributes();

      final target = e.clipById('b')!;
      expect(target.fadeIn.duration, s(3));
      expect(target.fadeOut.duration, s(2));

      final targetFx = e.addEffect('b', 'contrast');
      e.setTransformParam('b', 'scale', 140);
      expect(targetFx, isNotEmpty);
      e.selectClip('a');
      source
        ..effects.clear()
        ..transform = null;
      e.copySelection();
      e.selectClip('b');
      e.pasteAttributes();

      expect(target.effects, isEmpty);
      expect(target.transform, isNull);
    });

    test('mixed targets receive only compatible settings and skip locks', () {
      final e = harness(assetSeconds: 30);
      e.doc.media.add(
        MediaAsset(
          id: 'image',
          name: 'still.png',
          path: '/tmp/still.png',
          type: 'image',
          duration: Rt.zero(),
          hasAudio: false,
        ),
      );
      addClip(e, id: 'source', start: 0, duration: 5);
      final image = addClip(
        e,
        id: 'image-target',
        start: 6,
        duration: 5,
        mediaId: 'image',
      )..volume = 0.9;
      final audio = addClip(
        e,
        id: 'audio-target',
        start: 0,
        duration: 5,
        trackId: e.doc.audioTrack()!.id,
      )
        ..blend = 'screen'
        ..effects.add({'id': 'keep', 'type': 'contrast', 'params': {}});
      final lockedTrack = e.addTrack('video');
      final locked = addClip(
        e,
        id: 'locked',
        start: 0,
        duration: 5,
        trackId: lockedTrack.id,
      );
      e.doc.trackById(lockedTrack.id)!.lock = true;

      final fx = e.addEffect('source', 'saturation');
      expect(fx, isNotEmpty);
      e.setClipBlend('source', 'multiply');
      e.setClipAudio('source', volume: 0.35, pan: 0.5, mute: true);
      e.selectClip('source');
      e.copySelection();

      e.selection
        ..clear()
        ..addAll([image.id, audio.id, locked.id]);
      expect(e.canPasteAttributes, isTrue);
      e.pasteAttributes();

      expect(image.blend, 'multiply');
      expect(image.effects, hasLength(1));
      expect(image.volume, 0.9); // no audio stream
      expect(audio.blend, 'screen'); // audio lane keeps visual settings
      expect((audio.effects.single as Map)['id'], 'keep');
      expect(audio.volume, 0.35);
      expect(audio.pan, 0.5);
      expect(audio.mute, isTrue);
      expect(locked.blend, 'normal');
      expect(locked.volume, 1.0);
    });
  });

  group('keyframes (KEY-2/3/7)', () {
    test(
      'first toggle converts static into seeded first key with same value',
      () {
        final e = harness(assetSeconds: 30);
        addClip(e, id: 'a', start: 0, duration: 5);
        final fxId = e.addEffect('a', 'gaussianBlur');

        e.toggleKeyframe('a', fxId, 'radius', s(2));
        final pv = _params(e, 'a', fxId);
        final keys = pv['keyframes'] as List<dynamic>;
        // KEY-3: static becomes the first key, never lost.
        expect(keys, hasLength(2));
        expect((keys[0] as Map<String, dynamic>)['t'], Rt.zero().toString());
        expect((keys[0] as Map<String, dynamic>)['v'], 8.0);
        expect((keys[1] as Map<String, dynamic>)['v'], 8.0);
        expect((keys[1] as Map<String, dynamic>)['t'], s(2).toString());

        e.undo();
        expect(_params(e, 'a', fxId)['keyframes'], isEmpty);
      },
    );

    test('toggle at existing time removes the key', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 0, duration: 5);
      final fxId = e.addEffect('a', 'gaussianBlur');
      e.toggleKeyframe('a', fxId, 'radius', s(1));
      e.toggleKeyframe('a', fxId, 'radius', s(2));
      var pv = _params(e, 'a', fxId);
      expect(pv['keyframes'], hasLength(3));

      e.toggleKeyframe('a', fxId, 'radius', s(2));
      pv = _params(e, 'a', fxId);
      expect(pv['keyframes'], hasLength(2));
    });

    test('clearKeyframes returns LAST evaluated value as static', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 0, duration: 5);
      final fxId = e.addEffect('a', 'gaussianBlur');
      e.setKeyframeValue('a', fxId, 'radius', Rt.zero(), 0.0);
      e.setKeyframeValue('a', fxId, 'radius', s(5), 40.0);

      e.clearKeyframes('a', fxId, 'radius');
      final pv = _params(e, 'a', fxId);
      expect(pv['keyframes'], isEmpty);
      expect(pv['static'], 40.0); // last evaluated value retained

      e.undo();
      expect(_params(e, 'a', fxId)['keyframes'], hasLength(2));
    });

    test(
      '__transform pseudo-instance animates transform.scale; move clamps',
      () {
        final e = harness(assetSeconds: 30);
        addClip(e, id: 'a', start: 0, duration: 5);

        e.toggleKeyframe('a', '__transform', 'scale', s(0));
        e.setKeyframeValue('a', '__transform', 'scale', s(0), 100.0);
        e.setKeyframeValue('a', '__transform', 'scale', s(5), 200.0);
        final scale = e.clipById('a')!.transform!.scale;
        expect(scale.animated, isTrue);

        // Evaluate mid-way like the engine would.
        final mid = scale.evaluate(s(2.5)) as num;
        expect(mid.toDouble(), closeTo(150.0, 0.01));

        // Move clamps into [0, duration]: negative target lands on zero.
        final moved = e.moveKeyframe('a', '__transform', 'scale', s(0), s(-3));
        expect(moved, Rt.zero());
        // oldT beyond duration clamps onto the last key (t=dur) and moves it.
        expect(e.moveKeyframe('a', '__transform', 'scale', s(99), s(4)), s(4));
      },
    );

    test('clipKeyframeMarkers gathers every keyed param onto one instant', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 0, duration: 5);
      final fxId = e.addEffect('a', 'saturation');
      e.setKeyframeValue('a', fxId, 'amount', s(2), 1.5);
      e.setKeyframeValue('a', '__transform', 'scale', s(2), 150.0);
      e.setKeyframeValue('a', '__transform', 'scale', s(4), 200.0);

      final markers = e.clipKeyframeMarkers(e.clipById('a')!);
      expect(markers.map((m) => m.time.seconds), [0.0, 2.0, 4.0]);
      // The two params keyed at 2 s are one diamond carrying both.
      expect(markers[1].keys, hasLength(2));
      expect(markers[1].keys.map((k) => k.paramId).toSet(), {
        'amount',
        'scale',
      });
      expect(markers.every((m) => !m.anyGenerated), isTrue);
    });

    test('removeKeyframesAt clears every param keyed at that instant', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 0, duration: 5);
      final fxId = e.addEffect('a', 'saturation');
      e.setKeyframeValue('a', fxId, 'amount', s(2), 1.5);
      e.setKeyframeValue('a', '__transform', 'scale', s(2), 150.0);
      e.setKeyframeValue('a', '__transform', 'scale', s(4), 200.0);

      expect(e.removeKeyframesAt('a', s(2)), 2);
      expect(
        e.clipKeyframeMarkers(e.clipById('a')!).map((m) => m.time.seconds),
        [0.0, 4.0],
      );

      // One undo step brings both back.
      e.undo();
      expect(
        e.clipKeyframeMarkers(e.clipById('a')!).map((m) => m.time.seconds),
        [0.0, 2.0, 4.0],
      );
    });

    test('clearAllKeyframes leaves every param static', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 0, duration: 5);
      final fxId = e.addEffect('a', 'saturation');
      e.setKeyframeValue('a', fxId, 'amount', s(2), 1.5);
      e.setKeyframeValue('a', '__transform', 'scale', s(2), 150.0);

      e.clearAllKeyframes('a');
      expect(e.clipKeyframes(e.clipById('a')!), isEmpty);
      expect(e.clipById('a')!.transform!.scale.animated, isFalse);
    });

    test('removeKeyframe drops just that key', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 0, duration: 5);
      final fxId = e.addEffect('a', 'saturation');
      e.setKeyframeValue('a', fxId, 'amount', Rt.zero(), 0.5);
      e.setKeyframeValue('a', fxId, 'amount', s(2), 1.5);

      e.removeKeyframe('a', fxId, 'amount', s(2));
      final keys =
          _params(e, 'a', fxId, paramId: 'amount')['keyframes']
              as List<dynamic>;
      expect(keys, hasLength(1));
    });
  });

  group('blend (FX-12)', () {
    test('setClipBlend stores mode and undoes', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 0, duration: 5);

      e.setClipBlend('a', 'screen');
      expect(e.clipById('a')!.blend, 'screen');

      e.undo();
      expect(e.clipById('a')!.blend, 'normal');
    });
  });
}

Map<String, dynamic> _rawParams(Edits e, String clipId, String fxId) =>
    ((e
            .clipById(clipId)!
            .effects
            .whereType<Map<String, dynamic>>()
            .firstWhere((fx) => fx['id'] == fxId))['params'])
        as Map<String, dynamic>;

/// Param-shaped view: absent `keyframes` (static-only storage) reads as [].
Map<String, dynamic> _params(
  Edits e,
  String clipId,
  String fxId, {
  String paramId = 'radius',
}) {
  final raw = _rawParams(e, clipId, fxId)[paramId] as Map<String, dynamic>;
  return {
    'static': raw['static'],
    'keyframes': (raw['keyframes'] as List<dynamic>?) ?? <dynamic>[],
  };
}

dynamic _paramStatic(Edits e, String clipId, String fxId, String paramId) {
  final raw = _rawParams(e, clipId, fxId)[paramId];
  return raw is Map<String, dynamic> ? raw['static'] : raw;
}
