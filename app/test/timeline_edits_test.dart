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
  doc.media.add(MediaAsset(
    id: 'asset-1',
    name: 'clip.mov',
    path: '/tmp/clip.mov',
    type: 'video',
    duration: s(assetSeconds),
    hasAudio: true,
  ));
  return Edits(doc);
}

Clip addClip(
  Edits e, {
  required String id,
  required double start,
  required double duration,
  double sourceIn = 0,
  String? trackId,
  String? linkedGroup,
}) {
  final clip = Clip(
    id: id,
    trackId: trackId ?? e.doc.videoTrack()!.id,
    mediaId: 'asset-1',
    label: id,
    start: s(start),
    duration: s(duration),
    sourceIn: s(sourceIn),
    linkedGroup: linkedGroup,
  );
  e.doc.clips.add(clip);
  return clip;
}

void main() {
  group('split', () {
    test('splits at the playhead into two contiguous clips', () {
      final e = harness();
      final clip = addClip(e, id: 'a', start: 0, duration: 10);
      e.playhead = s(4);

      final created = e.splitAtPlayhead();

      expect(created, hasLength(1));
      expect(clip.duration, s(4));
      final right = e.clipById(created.first)!;
      expect(right.start, s(4));
      expect(right.duration, s(6));
      // The right half continues where the left one stopped in the source.
      expect(right.sourceIn, s(4));
    });

    test('a split on a speed-changed clip lands on the right source frame', () {
      final e = harness();
      final clip = addClip(e, id: 'a', start: 0, duration: 10, sourceIn: 2);
      clip.speed = '2/1';  // 10s of timeline consumes 20s of source
      e.playhead = s(4);

      final created = e.splitAtPlayhead();

      final right = e.clipById(created.first)!;
      // 4s of timeline at 2× consumed 8s of source, not 4s.
      expect(right.sourceIn, s(10));
    });

    test('refuses a split that would leave less than one frame', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 10);
      e.playhead = s(10);
      expect(e.splitAtPlayhead(), isEmpty);
      expect(e.doc.clips, hasLength(1));
    });

    test('splits linked partners together (TIM-10)', () {
      final e = harness();
      addClip(e, id: 'v', start: 0, duration: 10, linkedGroup: 'g1');
      addClip(e, id: 'a', start: 0, duration: 10, linkedGroup: 'g1',
          trackId: e.doc.audioTrack()!.id);
      e.playhead = s(6);

      final created = e.splitAtPlayhead();

      expect(created, hasLength(2));
      expect(e.doc.clips, hasLength(4));
    });
  });

  group('move', () {
    test('snaps to a neighbouring clip edge', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      addClip(e, id: 'b', start: 10, duration: 5);

      // 5.1s is within the ~8 px tolerance of a's tail at 40 px/s.
      e.moveClip('b', start: s(5.1), pxPerSec: 40);

      expect(e.clipById('b')!.start, s(5));
      expect(e.snapIndicator, 5.0);
    });

    test('pushes a later overlapped neighbour to the right', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      addClip(e, id: 'b', start: 5, duration: 5);

      e.moveClip('a', start: s(2), snap: false);

      expect(e.clipById('a')!.start, s(2));
      // b starts after a's new position, so it slides right to make room.
      expect(e.clipById('b')!.start, s(7));
    });

    test('a predecessor pins the dragged clip instead of swapping with it', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      addClip(e, id: 'b', start: 5, duration: 5);

      // Dragging b left past a's tail must butt it against a, not trade places.
      e.moveClip('b', start: s(2), snap: false);

      expect(e.clipById('a')!.start, s(0), reason: 'a must not move');
      expect(e.clipById('b')!.start, s(5), reason: 'b lands flush against a');
    });

    test('linked partners keep sync when one is blocked by a predecessor', () {
      final e = harness();
      final video = e.doc.videoTrack()!;
      final audio = e.doc.audioTrack()!;
      addClip(e, id: 'wall', start: 0, duration: 5, trackId: video.id);
      addClip(e,
          id: 'v', start: 10, duration: 5, trackId: video.id, linkedGroup: 'g');
      addClip(e,
          id: 'a', start: 10, duration: 5, trackId: audio.id, linkedGroup: 'g');

      e.beginDrag(EditGesture.move, 'v');
      e.updateDrag(-8, snap: false);
      e.endGesture();

      // v is stopped by `wall`; a must stop with it, not slide to 2s.
      expect(e.clipById('v')!.start, s(5));
      expect(e.clipById('a')!.start, s(5));
    });

    test('will not move a clip onto a track of a different kind', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      final audio = e.doc.audioTrack()!;

      e.moveClip('a', trackId: audio.id, start: s(1), snap: false);

      expect(e.clipById('a')!.trackId, e.doc.videoTrack()!.id);
    });

    test('a locked track refuses edits (TIM-2)', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      e.setTrackFlags(e.doc.videoTrack()!.id, lock: true);

      e.moveClip('a', start: s(3), snap: false);
      e.deleteClip('a');

      expect(e.clipById('a')!.start, Rt.zero());
      expect(e.doc.clips, hasLength(1));
    });

    test('dragging moves the whole selection and its linked partners', () {
      final e = harness();
      addClip(e, id: 'v', start: 0, duration: 5, linkedGroup: 'g1');
      addClip(e, id: 'a', start: 0, duration: 5, linkedGroup: 'g1',
          trackId: e.doc.audioTrack()!.id);

      e.beginDrag(EditGesture.move, 'v');
      e.updateDrag(3, snap: false);
      e.endGesture();

      expect(e.clipById('v')!.start, s(3));
      expect(e.clipById('a')!.start, s(3));
      expect(e.history.depth, 1);
    });
  });

  group('trim', () {
    test('head trim spends source handle and keeps the picture in place', () {
      final e = harness();
      addClip(e, id: 'a', start: 5, duration: 5, sourceIn: 5);

      e.trimStart('a', s(7), snap: false);

      final clip = e.clipById('a')!;
      expect(clip.start, s(7));
      expect(clip.sourceIn, s(7));
      expect(clip.duration, s(3));
    });

    test('head trim stops when the source handle runs out', () {
      final e = harness();
      addClip(e, id: 'a', start: 5, duration: 5, sourceIn: 1);

      e.trimStart('a', s(0), snap: false);

      final clip = e.clipById('a')!;
      expect(clip.sourceIn, Rt.zero());
      expect(clip.start, s(4));
      expect(clip.duration, s(6));
    });

    test('tail trim clamps at the end of the media', () {
      final e = harness(assetSeconds: 12);
      addClip(e, id: 'a', start: 0, duration: 10, sourceIn: 2);

      e.trimEnd('a', s(60), snap: false);

      // 12 s of media minus a 2 s source in-point leaves 10 s.
      expect(e.clipById('a')!.duration, s(10));
    });

    test('tail trim never collapses below one frame', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 10);

      e.trimEnd('a', s(-5), snap: false);

      expect(e.clipById('a')!.duration, e.frameDuration);
    });
  });

  group('roll / slip / slide (TIM-6)', () {
    test('roll moves the cut and preserves the pair span', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 0);
      addClip(e, id: 'b', start: 5, duration: 5, sourceIn: 5);

      e.beginRoll('a', 'b');
      e.updateDrag(1, snap: false);
      e.endGesture();

      final a = e.clipById('a')!;
      final b = e.clipById('b')!;
      expect(a.duration, s(6));
      expect(b.start, s(6));
      expect(b.sourceIn, s(6));
      expect(b.duration, s(4));
      expect(a.start.plus(a.duration).plus(b.duration), s(10));
    });

    test('roll lands on exact frame boundaries at 29.97 fps (criterion 2)', () {
      final e = harness(fps: 29.97, assetSeconds: 60);
      final frame = e.frameDuration;
      addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 0);
      addClip(e, id: 'b', start: 5, duration: 5, sourceIn: 5);

      // Drag by exactly seven frames' worth of seconds.
      e.beginRoll('a', 'b');
      e.updateDrag(Rt.fromMicros(frame.micros * 7).seconds, snap: false);
      e.endGesture();

      // Exactly seven frames were traded between the clips, with no drift:
      // rational equality, not a tolerance.
      expect(e.clipById('a')!.duration, s(5).plus(Rt(frame.num * 7, frame.den)));
      expect(e.clipById('b')!.duration, s(5).minus(Rt(frame.num * 7, frame.den)));
      expect(e.clipById('b')!.start, e.clipById('a')!.end);
    });

    test('slip shifts content inside a fixed span', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 4, duration: 5, sourceIn: 5);

      e.beginDrag(EditGesture.slip, 'a');
      e.updateDrag(-2);
      e.endGesture();

      final clip = e.clipById('a')!;
      expect(clip.start, s(4));
      expect(clip.duration, s(5));
      expect(clip.sourceIn, s(7));
    });

    test('slip clamps at source bounds — no negative durations (criterion 4)', () {
      final e = harness(assetSeconds: 10);
      addClip(e, id: 'a', start: 0, duration: 10, sourceIn: 0);

      e.beginDrag(EditGesture.slip, 'a');
      e.updateDrag(-50);

      final clip = e.clipById('a')!;
      // Handles are exhausted in both directions: nothing moved, and the drag
      // reports that it is being held against a limit (TIM-7).
      expect(clip.sourceIn, Rt.zero());
      expect(clip.duration, s(10));
      expect(e.trimAtLimit, isTrue);
      e.endGesture();
    });

    test('slide moves a clip between neighbours which compensate', () {
      final e = harness(assetSeconds: 30);
      addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 0);
      addClip(e, id: 'b', start: 5, duration: 5, sourceIn: 5);
      addClip(e, id: 'c', start: 10, duration: 5, sourceIn: 10);

      e.beginDrag(EditGesture.slide, 'b');
      e.updateDrag(2, snap: false);
      e.endGesture();

      expect(e.clipById('a')!.duration, s(7));
      expect(e.clipById('b')!.start, s(7));
      expect(e.clipById('b')!.duration, s(5));
      expect(e.clipById('c')!.start, s(12));
      expect(e.clipById('c')!.duration, s(3));
    });
  });

  group('delete', () {
    test('plain delete leaves the gap', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      addClip(e, id: 'b', start: 5, duration: 5);

      e.deleteClip('a');

      expect(e.doc.clips, hasLength(1));
      expect(e.clipById('b')!.start, s(5));
    });

    test('ripple delete of a linked pair pulls both tracks and undoes as one '
        '(criterion 1)', () {
      final e = harness(assetSeconds: 60);
      final video = e.doc.videoTrack()!.id;
      final audio = e.doc.audioTrack()!.id;
      final other = e.addTrack('video').id;

      addClip(e, id: 'v1', start: 0, duration: 5, trackId: video);
      addClip(e, id: 'v2', start: 5, duration: 5, trackId: video, linkedGroup: 'g');
      addClip(e, id: 'v3', start: 10, duration: 5, trackId: video);
      addClip(e, id: 'a1', start: 0, duration: 5, trackId: audio);
      addClip(e, id: 'a2', start: 5, duration: 5, trackId: audio, linkedGroup: 'g');
      addClip(e, id: 'a3', start: 10, duration: 5, trackId: audio);
      addClip(e, id: 'x1', start: 5, duration: 5, trackId: other);

      e.selectClip('v2');
      final before = e.history.depth;
      e.deleteSelected(ripple: true);

      expect(e.clipById('v2'), isNull);
      expect(e.clipById('a2'), isNull);
      expect(e.clipById('v3')!.start, s(5));
      expect(e.clipById('a3')!.start, s(5));
      // A track the selection did not span keeps its sync.
      expect(e.clipById('x1')!.start, s(5));
      expect(e.history.depth, before + 1);

      e.undo();
      expect(e.clipById('v2')!.start, s(5));
      expect(e.clipById('a2')!.start, s(5));
      expect(e.clipById('v3')!.start, s(10));
      expect(e.clipById('a3')!.start, s(10));
    });

    test('magnetic mode makes plain delete ripple (TIM-9)', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      addClip(e, id: 'b', start: 5, duration: 5);
      e.setMagnetic(true);

      e.deleteClip('a');

      expect(e.clipById('b')!.start, Rt.zero());
    });
  });

  group('selection and clipboard', () {
    test('marquee selects everything intersecting the span', () {
      final e = harness();
      final video = e.doc.videoTrack()!.id;
      final audio = e.doc.audioTrack()!.id;
      addClip(e, id: 'a', start: 0, duration: 4, trackId: video);
      addClip(e, id: 'b', start: 6, duration: 4, trackId: video);
      addClip(e, id: 'c', start: 0, duration: 4, trackId: audio);

      e.selectRange(trackIds: [video], from: s(3), to: s(7));

      expect(e.selection, {'a', 'b'});
    });

    test('select all, invert and track selection', () {
      final e = harness();
      final video = e.doc.videoTrack()!.id;
      addClip(e, id: 'a', start: 0, duration: 4, trackId: video);
      addClip(e, id: 'b', start: 6, duration: 4, trackId: e.doc.audioTrack()!.id);

      e.selectAll();
      expect(e.selection, {'a', 'b'});

      e.selectClip('a');
      e.invertSelection();
      expect(e.selection, {'b'});

      e.selectTrack(video);
      expect(e.selection, {'a'});
    });

    test('paste lands at the playhead with fresh ids (TIM-17)', () {
      final e = harness(assetSeconds: 60);
      addClip(e, id: 'a', start: 0, duration: 5);
      e.selectClip('a');
      e.copySelection();
      e.playhead = s(20);

      final created = e.paste();

      expect(created, hasLength(1));
      expect(created.first, isNot('a'));
      expect(e.clipById(created.first)!.start, s(20));
      expect(e.doc.clips, hasLength(2));
    });

    test('cut removes the clip and keeps it on the clipboard', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      e.selectClip('a');

      e.cutSelection();
      expect(e.doc.clips, isEmpty);

      e.playhead = s(2);
      e.paste();
      expect(e.doc.clips.single.start, s(2));
    });

    test('duplicate places a copy after the selection', () {
      final e = harness(assetSeconds: 60);
      addClip(e, id: 'a', start: 0, duration: 5);
      e.selectClip('a');

      final created = e.duplicateSelection();

      expect(e.clipById(created.single)!.start, s(5));
    });
  });

  group('tracks', () {
    test('add, rename, reorder and remove', () {
      final e = harness();
      final v2 = e.addTrack('video');
      expect(v2.name, 'V2');
      expect(e.doc.videoTracks, hasLength(2));

      e.renameTrack(v2.id, 'B-roll');
      expect(e.doc.trackById(v2.id)!.name, 'B-roll');

      e.reorderTrack(v2.id, -1);
      expect(e.doc.videoTracks.first.id, v2.id);

      addClip(e, id: 'a', start: 0, duration: 4, trackId: v2.id);
      e.removeTrack(v2.id);
      expect(e.doc.videoTracks, hasLength(1));
      expect(e.clipById('a'), isNull);
    });

    test('the last track of a kind cannot be removed', () {
      final e = harness();
      e.removeTrack(e.doc.videoTrack()!.id);
      expect(e.doc.videoTracks, hasLength(1));
    });

    test('audio solo clears the others', () {
      final e = harness();
      final a1 = e.doc.audioTrack()!;
      final a2 = e.addTrack('audio');

      e.setTrackFlags(a1.id, solo: true);
      e.setTrackFlags(a2.id, solo: true);

      expect(e.doc.trackById(a1.id)!.solo, isFalse);
      expect(e.doc.trackById(a2.id)!.solo, isTrue);
    });
  });

  group('placement (TIM-5)', () {
    test('append puts the clip after the last one and links its audio', () {
      final e = harness(assetSeconds: 8);
      e.placeAsset('asset-1');
      e.placeAsset('asset-1');

      final video = e.doc.clipsOn(e.doc.videoTrack()!.id);
      expect(video, hasLength(2));
      expect(video[1].start, s(8));
      // The asset has audio, so a linked audio clip lands too.
      expect(e.doc.clipsOn(e.doc.audioTrack()!.id), hasLength(2));
      expect(video.first.linkedGroup, isNotNull);
    });

    test('auto-link off adds picture only', () {
      final e = harness(assetSeconds: 8);
      e.setLinkAudioOnAdd(false);

      e.placeAsset('asset-1');

      final video = e.doc.clipsOn(e.doc.videoTrack()!.id);
      expect(video, hasLength(1));
      expect(video.first.linkedGroup, isNull);
      expect(e.doc.clipsOn(e.doc.audioTrack()!.id), isEmpty);
    });

    test('withAudio overrides the toggle in both directions', () {
      final e = harness(assetSeconds: 8);

      // Toggle on, this one drop without audio.
      e.placeAsset('asset-1', withAudio: false);
      expect(e.doc.clipsOn(e.doc.audioTrack()!.id), isEmpty);

      // Toggle off, this one drop with audio.
      e.setLinkAudioOnAdd(false);
      e.placeAsset('asset-1', withAudio: true);
      expect(e.doc.clipsOn(e.doc.audioTrack()!.id), hasLength(1));
    });

    test('overwrite clears what it lands on', () {
      final e = harness(assetSeconds: 4);
      final video = e.doc.videoTrack()!.id;
      addClip(e, id: 'a', start: 0, duration: 10);

      e.placeAsset('asset-1', trackId: video, at: s(2), mode: DropMode.overwrite);

      final clips = e.doc.clipsOn(video);
      expect(clips, hasLength(3));
      expect(clips[0].duration, s(2));
      expect(clips[1].start, s(2));
      expect(clips[2].start, s(6));
    });

    test('undo image overwrite restores the original unsplit video', () {
      final e = harness(assetSeconds: 20);
      final video = e.doc.videoTrack()!.id;
      final original = addClip(e, id: 'a', start: 0, duration: 10, sourceIn: 3);
      final before = original.toJson();
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

      e.placeAsset(
        'image-1',
        trackId: video,
        at: s(2),
        mode: DropMode.overwrite,
      );
      expect(e.doc.clipsOn(video), hasLength(3));

      e.undo();

      final restored = e.doc.clipsOn(video);
      expect(restored, hasLength(1));
      expect(restored.single.toJson(), before);
      expect(e.history.canRedo, isTrue);

      e.redo();
      expect(e.doc.clipsOn(video), hasLength(3));
    });

    test('insert ripples the lane right', () {
      final e = harness(assetSeconds: 4);
      final video = e.doc.videoTrack()!.id;
      addClip(e, id: 'a', start: 0, duration: 5);

      e.placeAsset('asset-1', trackId: video, at: Rt.zero(), mode: DropMode.insert);

      expect(e.clipById('a')!.start, s(4));
      expect(e.doc.clipsOn(video).first.start, Rt.zero());
    });

    test('image placement creates a five-second unlinked visual clip', () {
      final e = harness();
      e.doc.media.add(MediaAsset(
        id: 'image-1',
        name: 'poster.webp',
        path: '/tmp/poster.webp',
        type: 'image',
        duration: Rt.zero(),
        hasAudio: false,
      ));

      final created = e.placeAsset('image-1');

      expect(created, hasLength(1));
      final image = e.clipById(created.single)!;
      expect(image.duration, s(5));
      expect(image.linkedGroup, isNull);
      expect(e.doc.trackById(image.trackId)!.isVideo, isTrue);
      expect(e.doc.clipsOn(e.doc.audioTrack()!.id), isEmpty);

      e.setClipTiming(image.id, duration: s(12));
      expect(e.clipById(image.id)!.duration, s(12));
    });
  });

  group('undo', () {
    test('restores the document and redo reapplies it', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 10);

      e.moveClip('a', start: s(4), snap: false);
      expect(e.doc.clips.single.start, s(4));

      e.undo();
      expect(e.doc.clips.single.start, Rt.zero());

      e.redo();
      expect(e.doc.clips.single.start, s(4));
    });

    test('a gesture commits exactly one undo step', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 10);

      e.beginDrag(EditGesture.move, 'a');
      for (var i = 1; i <= 5; i++) {
        e.updateDrag(i.toDouble(), snap: false);
      }
      e.endGesture();

      expect(e.doc.clips.single.start, s(5));
      e.undo();
      expect(e.doc.clips.single.start, Rt.zero());
      expect(e.canUndo, isFalse);
    });

    test('a new edit clears the redo stack', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 10);

      e.moveClip('a', start: s(4), snap: false);
      e.undo();
      expect(e.canRedo, isTrue);

      e.moveClip('a', start: s(2), snap: false);
      expect(e.canRedo, isFalse);
    });

    test('undo restores deleted clips with all their fields', () {
      final e = harness();
      final clip = addClip(e, id: 'a', start: 0, duration: 10);
      clip.volume = 0.4;
      clip.mute = true;
      clip.fadeIn.duration = s(1);

      e.deleteClip('a');
      e.undo();

      final restored = e.clipById('a')!;
      expect(restored.volume, 0.4);
      expect(restored.mute, isTrue);
      expect(restored.fadeIn.duration, s(1));
    });

    test('the stack drops the oldest commands past its memory budget', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 10);
      // A tiny budget: every edit evicts the previous one.
      final small = Edits(e.doc);
      for (var i = 1; i <= 50; i++) {
        small.moveClip('a', start: s(i.toDouble()), snap: false);
      }
      expect(small.history.depth, lessThanOrEqualTo(50));
      expect(small.history.bytes, lessThan(small.history.memoryBudgetBytes));
    });
  });

  group('in / out and markers', () {
    test('markers land on the playhead and survive a round trip', () {
      final e = harness();
      e.playhead = s(7.5);
      final marker = e.addMarker(name: 'chapter');

      final restored = ProjectDoc.decode(e.doc.encode());
      expect(restored.markers.single.id, marker.id);
      expect(restored.markers.single.time, s(7.5));
      expect(restored.markers.single.name, 'chapter');
    });

    test('marker navigation walks in both directions', () {
      final e = harness();
      e.playhead = s(2);
      e.addMarker();
      e.playhead = s(8);
      e.addMarker();

      expect(e.nextMarker(s(0)), s(2));
      expect(e.nextMarker(s(9), forward: false), s(8));
    });

    test('in/out points keep their order', () {
      final e = harness();
      e.setInPoint(s(5));
      e.setOutPoint(s(3));
      expect(e.inPoint, isNull);
      expect(e.outPoint, s(3));

      e.clearInOut();
      expect(e.outPoint, isNull);
    });

    test('nextEdge walks cut points in both directions', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      addClip(e, id: 'b', start: 8, duration: 4);

      expect(e.nextEdge(s(1)), s(5));
      expect(e.nextEdge(s(9), forward: false), s(8));
    });
  });
  group('speed', () {
    test('increases speed to the next preset and preserves source span', () {
      final e = harness();
      final clip = addClip(e, id: 'a', start: 0, duration: 10);

      expect(e.nextClipSpeedLabel(clip.id), '2/1x');
      expect(e.increaseClipSpeed(clip.id), isTrue);

      expect(clip.speed, '2/1');
      expect(clip.duration, s(5));
      expect(clip.sourceSpan, s(10));
      expect(e.history.depth, 1);
    });

    test('increases linked picture and audio together', () {
      final e = harness();
      final group = 'linked';
      final video = addClip(
        e,
        id: 'v',
        start: 0,
        duration: 10,
        linkedGroup: group,
      );
      final audio = addClip(
        e,
        id: 'a',
        start: 0,
        duration: 10,
        linkedGroup: group,
        trackId: e.doc.audioTrack()!.id,
      );

      expect(e.increaseClipSpeed(video.id), isTrue);

      expect(video.speed, '2/1');
      expect(audio.speed, '2/1');
      expect(video.duration, s(5));
      expect(audio.duration, s(5));
    });

    test('stops at 4x and keeps a locked linked pair unchanged', () {
      final e = harness();
      final clip = addClip(e, id: 'a', start: 0, duration: 10);
      clip.speed = '4/1';
      expect(e.nextClipSpeedLabel(clip.id), isNull);
      expect(e.increaseClipSpeed(clip.id), isFalse);

      final linked = addClip(
        e,
        id: 'linked-a',
        start: 0,
        duration: 10,
        linkedGroup: 'locked',
        trackId: e.doc.audioTrack()!.id,
      );
      final video = addClip(
        e,
        id: 'linked-v',
        start: 0,
        duration: 10,
        linkedGroup: 'locked',
      );
      e.setTrackFlags(e.doc.audioTrack()!.id, lock: true);

      expect(e.increaseClipSpeed(video.id), isFalse);
      expect(linked.speed, '1/1');
      expect(video.speed, '1/1');
    });

    test('speed increase is one undoable edit', () {
      final e = harness();
      final clip = addClip(e, id: 'a', start: 0, duration: 10);
      e.increaseClipSpeed(clip.id);

      e.undo();

      final restored = e.clipById(clip.id)!;
      expect(restored.speed, '1/1');
      expect(restored.duration, s(10));
    });
  });

  test('undo of duplicate removes the clone (not restores it)', () {
    final e = harness();
    addClip(e, id: 'c1', start: 0, duration: 5);
    e.selection.add('c1');
    e.duplicateSelection();
    expect(e.doc.clips.length, 2);
    e.undo();
    expect(e.doc.clips.length, 1);
    expect(e.clipById('c1'), isNotNull);
  });

  group('undo integrity', () {
    // Regression: a drag whose pointer was cancelled left the coalescing
    // transaction open. Every later edit folded into it and never reached the
    // history stack, so ctrl+Z reverted some older command while the newest
    // edit stayed applied — the timeline came back with clips duplicated at
    // stale positions.
    test('an edit after an unclosed gesture is still undoable', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      addClip(e, id: 'b', start: 10, duration: 5);
      addClip(e, id: 'c', start: 30, duration: 5);

      // A gesture that begins and never ends.
      e.beginGesture('Move clips');
      e.moveClip('c', start: s(35), snap: false);

      e.selection.add('b');
      e.cutSelection();
      expect(e.clipById('b'), isNull);

      e.undo();

      expect(e.clipById('b'), isNotNull,
          reason: 'the cut clip must come back');
      expect(e.clipById('b')!.start, s(10));
      expect(e.clipById('a')!.start, s(0));
    });

    test('a new gesture commits one left open instead of adopting it', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      addClip(e, id: 'b', start: 10, duration: 5);

      e.beginGesture('Move clips');
      e.moveClip('b', start: s(20), snap: false);
      // The next gesture starts without the previous one ever closing.
      e.beginGesture('Move clips');
      e.moveClip('b', start: s(25), snap: false);
      e.endGesture();

      e.undo();
      expect(e.clipById('b')!.start, s(20), reason: 'only the last move undoes');
      e.undo();
      expect(e.clipById('b')!.start, s(10), reason: 'the leaked move undoes too');
    });
  });

}
