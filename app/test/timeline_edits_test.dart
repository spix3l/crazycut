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

Edits harness({double assetSeconds = 20}) {
  final doc = ProjectDoc.empty('Test', width: 1920, height: 1080, fps: 30);
  doc.media.add(
    MediaAsset(
      id: 'asset-1',
      name: 'clip.mov',
      path: '/tmp/clip.mov',
      type: 'video',
      duration: s(assetSeconds),
      hasAudio: false,
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
}) {
  final clip = Clip(
    id: id,
    trackId: e.doc.videoTrack()!.id,
    mediaId: 'asset-1',
    label: id,
    start: s(start),
    duration: s(duration),
    sourceIn: s(sourceIn),
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

    test('refuses a split that would leave less than one frame', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 10);
      e.playhead = s(10);
      expect(e.splitAtPlayhead(), isEmpty);
      expect(e.doc.clips, hasLength(1));
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

    test('pushes an overlapped neighbour to the right', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      addClip(e, id: 'b', start: 5, duration: 5);

      e.moveClip('b', start: s(2), snap: false);

      expect(e.clipById('b')!.start, s(2));
      // a started before b's new position and overlaps it, so it slides past.
      expect(e.clipById('a')!.start, s(7));
    });

    test('will not move a clip onto a track of a different kind', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      final audio = e.doc.audioTrack()!;

      e.moveClip('a', trackId: audio.id, start: s(1), snap: false);

      expect(e.clipById('a')!.trackId, e.doc.videoTrack()!.id);
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

  group('delete', () {
    test('plain delete leaves the gap', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      addClip(e, id: 'b', start: 5, duration: 5);

      e.deleteClip('a');

      expect(e.doc.clips, hasLength(1));
      expect(e.clipById('b')!.start, s(5));
    });

    test('ripple delete pulls later clips on that track left', () {
      final e = harness();
      addClip(e, id: 'a', start: 0, duration: 5);
      addClip(e, id: 'b', start: 5, duration: 5);
      addClip(e, id: 'c', start: 10, duration: 5);

      e.deleteClip('a', ripple: true);

      expect(e.clipById('b')!.start, Rt.zero());
      expect(e.clipById('c')!.start, s(5));
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

      e.beginGesture();
      for (var i = 1; i <= 5; i++) {
        e.moveClip('a', start: s(i.toDouble()), snap: false);
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
  });

  test('markers land on the playhead and survive a round trip', () {
    final e = harness();
    e.playhead = s(7.5);
    final marker = e.addMarker(name: 'chapter');

    final restored = ProjectDoc.decode(e.doc.encode());
    expect(restored.markers.single.id, marker.id);
    expect(restored.markers.single.time, s(7.5));
    expect(restored.markers.single.name, 'chapter');
  });

  test('nextEdge walks cut points in both directions', () {
    final e = harness();
    addClip(e, id: 'a', start: 0, duration: 5);
    addClip(e, id: 'b', start: 8, duration: 4);

    expect(e.nextEdge(s(1)), s(5));
    expect(e.nextEdge(s(9), forward: false), s(8));
  });
}
