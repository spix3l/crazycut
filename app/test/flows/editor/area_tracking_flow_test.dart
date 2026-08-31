import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/project/domain/area_track.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';
import '../../support/temp_dir.dart';

/// Area tracking (`docs/03-features/tracking.md`, **TRK**) from the document's
/// side: what a tracker is, what survives a round trip, and what happens to a
/// pinned clip when the thing it follows changes or disappears.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUpAll(() async => tmp = await Directory.systemTemp.createTemp('cc-track'));
  tearDownAll(() => deleteTempDir(tmp));

  // A 1920x1080 sequence with a 1920x1080 source clip, so source px and
  // sequence px coincide and the expected numbers are readable.
  (_ProbeController, Clip, Clip) harness() {
    final doc = ProjectDoc.empty('P', width: 1920, height: 1080, fps: 30);
    doc.media.add(
      MediaAsset(
        id: 'video',
        name: 'shot.mov',
        path: '/tmp/shot.mov',
        type: 'video',
        duration: Rt.fromSeconds(12),
        hasAudio: true,
        width: 1920,
        height: 1080,
      ),
    );
    doc.media.add(
      MediaAsset(
        id: 'meme',
        name: 'face.png',
        path: '/tmp/face.png',
        type: 'image',
        duration: Rt.fromSeconds(12),
        hasAudio: false,
        width: 200,
        height: 200,
      ),
    );
    final tracks = doc.videoTracks;
    final source = Clip(
      id: 'source',
      trackId: tracks.first.id,
      mediaId: 'video',
      label: 'Shot',
      start: Rt.zero(),
      duration: Rt.fromSeconds(6),
      sourceIn: Rt.zero(),
    );
    final overlay = Clip(
      id: 'overlay',
      trackId: tracks.length > 1 ? tracks[1].id : tracks.first.id,
      mediaId: 'meme',
      label: 'Face',
      start: Rt.zero(),
      duration: Rt.fromSeconds(6),
      sourceIn: Rt.zero(),
    );
    doc.clips.addAll([source, overlay]);
    final controller = _ProbeController(doc, '${tmp.path}/track.crazycut');
    return (controller, source, overlay);
  }

  /// A tracker that slides a 400x300 box right by 10 px per sample.
  Tracker slidingTracker({String id = 't1', int samples = 4}) {
    final path = <double>[];
    final confidence = <double>[];
    for (var i = 0; i < samples; i += 1) {
      final x = 100.0 + i * 10;
      path.addAll([x, 200, x + 400, 200, x + 400, 500, x, 500]);
      confidence.add(1.0);
    }
    return Tracker(
      id: id,
      mediaId: 'video',
      sourceClipId: 'source',
      startTime: Rt.zero(),
      endTime: Rt.fromSeconds(samples / 30),
      searchQuad: const [100, 200, 500, 200, 500, 500, 100, 500],
      fps: Rt(30, 1),
      path: path,
      confidence: confidence,
    );
  }

  // --- Model ---------------------------------------------------------------

  group('model', () {
    test('a tracker round-trips through the project file', () {
      final (c, _, _) = harness();
      c.installTracker(slidingTracker());

      final reloaded = ProjectDoc.decode(c.doc.encode(touchModified: false));
      expect(reloaded.trackers, hasLength(1));
      final tracker = reloaded.trackers.first;
      expect(tracker.id, 't1');
      expect(tracker.sampleCount, 4);
      expect(tracker.fps, Rt(30, 1));
      expect(tracker.sample(0), const [100, 200, 500, 200, 500, 500, 100, 500]);
    });

    test('unknown tracker fields survive a round trip', () {
      // 02-data-model.md §9: forward-safe. A field a future build adds must not
      // be dropped by this one.
      final (c, _, _) = harness();
      final tracker = Tracker.fromJson({
        ...slidingTracker().toJson(),
        'futureField': {'shape': 'ellipse'},
      });
      c.installTracker(tracker!);
      final reloaded = ProjectDoc.decode(c.doc.encode(touchModified: false));
      expect(reloaded.trackers.first.extra['futureField'], {'shape': 'ellipse'});
    });

    test('malformed trackers are quarantined, not thrown', () {
      final base = slidingTracker().toJson();
      for (final broken in <Map<String, dynamic>>[
        {...base, 'id': ''},
        {...base, 'path': <double>[]},
        {...base, 'path': [1, 2, 3]},
        {...base, 'confidence': [1.0]},
        {...base, 'searchQuad': [1, 2]},
        {...base, 'fps': '0/1'},
        {...base, 'endTime': '0/1'},
      ]) {
        expect(Tracker.fromJson(broken), isNull, reason: broken.toString());
      }
    });

    test('a corrupt tracker does not take its siblings with it', () {
      final (c, _, _) = harness();
      final good = slidingTracker(id: 'good').toJson();
      final bad = {...slidingTracker(id: 'bad').toJson(), 'confidence': [1.0]};
      final json = ProjectDoc.decode(c.doc.encode(touchModified: false)).toJson()
        ..['trackers'] = [bad, good];

      final report = RepairReport();
      final doc = ProjectDoc.fromJson(json, report: report);
      expect(doc.trackers.map((t) => t.id), ['good']);
      expect(report.issues, isNotEmpty);
    });

    test('quadAt interpolates between stored samples', () {
      // TRK-14 lets the solver decimate, so a path is read between its samples.
      final tracker = slidingTracker();
      final half = tracker.quadAt(Rt(1, 60)); // half a sample in
      expect(half[0], closeTo(105, 1e-9));
      // Outside the solved range it holds its end pose rather than extrapolating.
      expect(tracker.quadAt(Rt.fromSeconds(-1))[0], 100);
      expect(tracker.quadAt(Rt.fromSeconds(99))[0], 130);
    });

    test('low-confidence spans are reported for the warning stripe', () {
      final tracker = Tracker(
        id: 't',
        mediaId: 'video',
        sourceClipId: 'source',
        startTime: Rt.zero(),
        endTime: Rt.fromSeconds(4 / 30),
        searchQuad: const [0, 0, 10, 0, 10, 10, 0, 10],
        fps: Rt(30, 1),
        path: List<double>.filled(32, 0),
        confidence: const [1.0, 0.1, 0.1, 1.0],
      );
      final spans = tracker.lowConfidenceSpans();
      expect(spans, hasLength(1));
      // Rt is microsecond-quantised, so this is exact to the tick, not to the
      // last bit of a double.
      expect(spans.first.start.seconds, closeTo(1 / 30, 1e-5));
      expect(spans.first.end.seconds, closeTo(3 / 30, 1e-5));
    });

    test('quad usability matches the compositor rule', () {
      expect(quadIsUsable(const [0, 0, 10, 0, 10, 10, 0, 10]), isTrue);
      // Collapsed, self-intersecting, and sub-pixel are all refused (TRK-25).
      expect(quadIsUsable(const [0, 0, 0, 0, 0, 0, 0, 0]), isFalse);
      expect(quadIsUsable(const [0, 0, 10, 0, 0, 10, 10, 10]), isFalse);
      expect(quadIsUsable(const [0, 0, 0.4, 0, 0.4, 0.4, 0, 0.4]), isFalse);
    });
  });

  // --- Ops ------------------------------------------------------------------

  group('ops', () {
    test('installing a solve is one undo step', () {
      final (c, _, _) = harness();
      c.installTracker(slidingTracker());
      expect(c.doc.trackers, hasLength(1));

      c.undo();
      expect(c.doc.trackers, isEmpty);
      c.redo();
      expect(c.doc.trackers, hasLength(1));
      expect(c.doc.trackers.first.sampleCount, 4);
    });

    test('pinning generates corner keyframes that follow the region', () {
      final (c, _, overlay) = harness();
      c.installTracker(slidingTracker());
      c.pinClipToTracker(overlay.id, 't1');

      final corners = c.doc.clipById('overlay')!.transform?.corners;
      expect(corners, isNotNull, reason: 'the pin should generate a quad');
      expect(corners!.animated, isTrue, reason: 'the region moves, so must it');
      expect(corners.keyframes, hasLength(4));

      // Corner pin follows the region exactly, offset by wherever the overlay
      // already was — so the *motion* is the region's, 10 px per sample.
      final first = (corners.evaluate(Rt.zero()) as List).cast<double>();
      final last = (corners.evaluate(Rt(3, 30)) as List).cast<double>();
      expect(last[0] - first[0], closeTo(30, 0.01));
      expect(last[1] - first[1], closeTo(0, 0.01));
    });

    test('a corner pin adopts the tracked region outright', () {
      // TRK-19. This is the face-swap case: the image lands *on* the region,
      // taking its position and its shape, not merely following its motion.
      final (c, _, overlay) = harness();
      c.installTracker(slidingTracker());
      c.pinClipToTracker(overlay.id, 't1');

      final corners = c.doc.clipById('overlay')!.transform!.corners!;
      final quad = (corners.evaluate(Rt.zero()) as List).cast<double>();
      // Source and sequence px coincide in this harness, so the first sample's
      // region is the quad verbatim.
      const expected = [100.0, 200.0, 500.0, 200.0, 500.0, 500.0, 100.0, 500.0];
      for (var i = 0; i < 8; i += 1) {
        expect(quad[i], closeTo(expected[i], 0.01), reason: 'component $i');
      }
    });

    test('a nudge shifts the overlay off the region and is kept', () {
      final (c, _, overlay) = harness();
      c.installTracker(slidingTracker());
      c.pinClipToTracker(overlay.id, 't1');
      c.nudgePin(overlay.id, const Offset(0, -40));

      final quad = (c.doc.clipById('overlay')!.transform!.corners!
              .evaluate(Rt.zero()) as List)
          .cast<double>();
      expect(quad[1], 160);
      expect(quad[0], 100, reason: 'a vertical nudge must not move it sideways');

      // A re-solve rebuilds the pose but must not discard the nudge.
      c.installTracker(slidingTracker());
      final after = (c.doc.clipById('overlay')!.transform!.corners!
              .evaluate(Rt.zero()) as List)
          .cast<double>();
      expect(after[1], 160);
    });

    test('position mode keeps the overlay its own size', () {
      final (c, _, overlay) = harness();
      c.installTracker(slidingTracker());
      c.pinClipToTracker(overlay.id, 't1', mode: PinMode.position);

      final corners = c.doc.clipById('overlay')!.transform!.corners!;
      final quad = (corners.evaluate(Rt.zero()) as List).cast<double>();
      final base = c.clipRectInSequence(c.doc.clipById('overlay')!)!;
      // The tracked region is 400x300; a position-only pin must not adopt that.
      expect(quad[2] - quad[0], closeTo(base.width, 0.01));
      expect(quad[5] - quad[1], closeTo(base.height, 0.01));
    });

    test('unpinning removes the pin and the pose it generated', () {
      final (c, _, overlay) = harness();
      c.installTracker(slidingTracker());
      c.pinClipToTracker(overlay.id, 't1');
      expect(c.doc.clipById('overlay')!.transform?.corners, isNotNull);

      c.unpinClip(overlay.id);
      final clip = c.doc.clipById('overlay')!;
      expect(clip.extra.containsKey(kTrackPinKey), isFalse);
      expect(clip.transform?.corners, isNull);

      c.undo();
      expect(c.doc.clipById('overlay')!.transform?.corners, isNotNull);
    });

    test('baking keeps the keyframes and drops the pin', () {
      // TRK-21: the user can leave the tracking system and hand-edit.
      final (c, _, overlay) = harness();
      c.installTracker(slidingTracker());
      c.pinClipToTracker(overlay.id, 't1');
      c.bakePinToKeyframes(overlay.id);

      final clip = c.doc.clipById('overlay')!;
      expect(clip.extra.containsKey(kTrackPinKey), isFalse);
      expect(clip.transform?.corners?.animated, isTrue);
    });

    test('deleting a tracker unpins what followed it', () {
      // TRK-22: never leave a clip asking for a pose nothing can supply.
      final (c, _, overlay) = harness();
      c.installTracker(slidingTracker());
      c.pinClipToTracker(overlay.id, 't1');

      c.deleteTracker('t1');
      final clip = c.doc.clipById('overlay')!;
      expect(c.doc.trackers, isEmpty);
      expect(clip.extra.containsKey(kTrackPinKey), isFalse);
      expect(clip.transform?.corners, isNull);
    });

    test('a re-solve rebuilds the pins that follow it', () {
      final (c, _, overlay) = harness();
      c.installTracker(slidingTracker());
      c.pinClipToTracker(overlay.id, 't1');
      final before = (c.doc
              .clipById('overlay')!
              .transform!
              .corners!
              .evaluate(Rt(3, 30)) as List)
          .cast<double>();

      // Same id, twice the motion.
      final faster = slidingTracker().copyWith(
        path: [
          for (var i = 0; i < 4; i += 1) ...[
            100.0 + i * 20, 200, 500.0 + i * 20, 200,
            500.0 + i * 20, 500, 100.0 + i * 20, 500,
          ],
        ],
      );
      c.installTracker(faster);
      final after = (c.doc
              .clipById('overlay')!
              .transform!
              .corners!
              .evaluate(Rt(3, 30)) as List)
          .cast<double>();
      expect(after[0] - before[0], closeTo(30, 0.01));
    });

    test('a pin to a missing tracker is dropped on load', () {
      final (c, _, overlay) = harness();
      c.installTracker(slidingTracker());
      c.pinClipToTracker(overlay.id, 't1');

      final json = c.doc.toJson()..['trackers'] = <dynamic>[];
      final report = RepairReport();
      final doc = ProjectDoc.fromJson(json, report: report);
      expect(
        doc.clipById('overlay')!.extra.containsKey(kTrackPinKey),
        isFalse,
      );
      expect(report.issues, isNotEmpty);
    });

    test('replacing a region places a pinned overlay in one step', () {
      // The feature in one action: no importing, no finding a free track, no
      // dragging a clip to the right range, no hunting for a tracker id.
      final (c, source, _) = harness();
      c.installTracker(slidingTracker());

      final id = c.replaceRegionWithAsset(trackerId: 't1', assetId: 'meme');
      expect(id, isNotNull);
      final overlay = c.doc.clipById(id!)!;

      // Spans exactly the tracked range, on a track above the tracked clip.
      expect(overlay.start, source.start + c.doc.trackers.first.startTime);
      expect(
        overlay.duration,
        c.doc.trackers.first.endTime - c.doc.trackers.first.startTime,
      );
      final above = c.doc.trackById(overlay.trackId)!;
      final below = c.doc.trackById(source.trackId)!;
      expect(above.index, greaterThan(below.index));

      // Pinned and already following the region.
      expect(TrackPin.fromExtra(overlay.extra)?.mode, PinMode.cornerPin);
      final quad = (overlay.transform!.corners!.evaluate(Rt.zero()) as List)
          .cast<double>();
      expect(quad[0], closeTo(100, 0.01));
      expect(quad[2], closeTo(500, 0.01));

      // And it is one undo step.
      c.undo();
      expect(c.doc.clipById(id), isNull);
    });

    test('replacing twice reuses a free track instead of stacking new ones', () {
      final (c, _, _) = harness();
      c.installTracker(slidingTracker(id: 'a'));
      final first = c.replaceRegionWithAsset(trackerId: 'a', assetId: 'meme');
      final tracksAfterFirst = c.doc.videoTracks.length;

      // A second tracker on a range that does not overlap the first overlay.
      c.installTracker(
        slidingTracker(id: 'b').copyWith(
          startTime: Rt.fromSeconds(2),
          endTime: Rt.fromSeconds(2 + 4 / 30),
        ),
      );
      final second = c.replaceRegionWithAsset(trackerId: 'b', assetId: 'meme');

      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(
        c.doc.videoTracks.length,
        tracksAfterFirst,
        reason: 'a free track should be reused, not stacked on',
      );
    });

    test('an image already in the project still resolves on import', () async {
      // IMP-3 dedupes by content hash, so a second import of the same file adds
      // nothing to doc.media. Detecting the asset by diffing that list made
      // "replace with image" work once and then do nothing at all.
      final (c, _, _) = harness();
      final png = File('${tmp.path}/dedupe.png');
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const ui.Rect.fromLTWH(0, 0, 32, 32),
        ui.Paint()..color = const ui.Color(0xFF00FF00),
      );
      final image = await recorder.endRecording().toImage(32, 32);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      png.writeAsBytesSync(bytes!.buffer.asUint8List());

      final first = await c.importAndResolve(png.path);
      expect(first, isNotNull, reason: 'the first import should land');

      final countAfterFirst = c.doc.media.length;
      final again = await c.importAndResolve(png.path);

      // The assertion the whole test rests on: the second import genuinely
      // added nothing, so anything reading "what appeared" would see nothing.
      expect(
        c.doc.media.length,
        countAfterFirst,
        reason: 'the second import should have been deduped, or this proves '
            'nothing about the bug it guards',
      );
      expect(again, isNotNull, reason: 'a deduped import still has an answer');
      expect(again!.id, first!.id, reason: 'and it is the same asset');
    });

    test('a region is anchored to the frame it was drawn on', () {
      // Drawing at frame 0 and drawing at 2 s are different requests: the box
      // is positioned for the frame the user is looking at, and the solve has
      // to start there. Anchoring both at the clip's start put the box on one
      // frame and solved from another, which is wrong from the first sample.
      final (c, source, _) = harness();
      final asked = <Rt>[];
      c.onSolveRequested = (start) => asked.add(start);

      c.seekTo(source.start + Rt.fromSeconds(2));
      c.trackRegion(
        source,
        quadFromRect(left: 100, top: 100, right: 500, bottom: 400),
      );
      expect(asked.single.seconds, closeTo(2, 1e-6));

      // An explicit range still wins, for a re-solve that knows its own bounds.
      asked.clear();
      c.trackRegion(
        source,
        quadFromRect(left: 100, top: 100, right: 500, bottom: 400),
        start: Rt.zero(),
      );
      expect(asked.single, Rt.zero());
    });

    test('a refused region says why instead of doing nothing', () {
      // The bug this exists for: dragging a box that cannot be tracked used to
      // return null silently, so the user let go of the mouse and nothing
      // whatsoever happened — indistinguishable from the tool being broken.
      final (c, source, _) = harness();

      // Too small.
      c.trackRegion(source, quadFromRect(left: 100, top: 100, right: 104, bottom: 104));
      expect(c.trackRejection, contains('too small'));

      // Off the picture.
      c.trackRegion(
        source,
        quadFromRect(left: -400, top: 100, right: -100, bottom: 400),
      );
      expect(c.trackRejection, contains('outside the picture'));

      c.clearTrackRejection();
      expect(c.trackRejection, isNull);
    });

    test('a solved region maps through the tracked clip own transform', () {
      // The point of storing the path in source px: shrink the footage and the
      // pinned overlay follows it down, because both go through one placement.
      final (c, source, overlay) = harness();
      c.installTracker(slidingTracker());
      c.pinClipToTracker(overlay.id, 't1', mode: PinMode.cornerPin);
      final full = (c.doc
              .clipById('overlay')!
              .transform!
              .corners!
              .evaluate(Rt.zero()) as List)
          .cast<double>();

      c.setTransformParam(source.id, 'scale', 50);
      c.rebuildAllPins();
      final halved = (c.doc
              .clipById('overlay')!
              .transform!
              .corners!
              .evaluate(Rt.zero()) as List)
          .cast<double>();

      final fullWidth = full[2] - full[0];
      final halvedWidth = halved[2] - halved[0];
      expect(fullWidth, closeTo(400, 0.01));
      expect(halvedWidth, closeTo(fullWidth / 2, 0.5));
    });

    test('sequence and source quads are inverses of each other', () {
      final (c, source, _) = harness();
      const region = [100.0, 200.0, 500.0, 200.0, 500.0, 500.0, 100.0, 500.0];
      final tracker = slidingTracker();
      c.installTracker(tracker);
      final inSequence = c.trackedQuadInSequence(tracker, source, Rt.zero())!;
      final back = c.sequenceQuadToSource(source, inSequence, Rt.zero())!;
      for (var i = 0; i < 8; i += 1) {
        expect(back[i], closeTo(region[i], 0.01), reason: 'component $i');
      }
    });
  });

  // --- Several regions on one clip (TRK-27) ---------------------------------

  group('multiple regions', () {
    /// A second region on the same clip, offset so the two never coincide.
    Tracker secondTracker({String id = 't2'}) => slidingTracker(id: id).copyWith(
      searchQuad: const [900, 600, 1300, 600, 1300, 900, 900, 900],
      path: [
        for (var i = 0; i < 4; i += 1) ...[
          900.0 + i * 10, 600, 1300.0 + i * 10, 600,
          1300.0 + i * 10, 900, 900.0 + i * 10, 900,
        ],
      ],
    );

    test('two regions on one clip coexist and round-trip', () {
      final (c, _, _) = harness();
      c.installTracker(slidingTracker());
      c.installTracker(secondTracker());

      final reloaded = ProjectDoc.decode(c.doc.encode(touchModified: false));
      expect(reloaded.trackersForClip('source').map((t) => t.id), ['t1', 't2']);
      // Each keeps its own path, rather than the second overwriting the first.
      expect(reloaded.trackerById('t1')!.sample(0)[0], 100);
      expect(reloaded.trackerById('t2')!.sample(0)[0], 900);
    });

    test('drawing again asks for a new region, not a re-solve of the old one', () {
      // The bug this replaces: a second box reused the first tracker's id, so
      // the solve landed on top of it and the first region simply vanished.
      final (c, source, _) = harness();
      c.installTracker(slidingTracker());

      c.trackRegion(
        source,
        quadFromRect(left: 900, top: 600, right: 1300, bottom: 900),
      );
      expect(c.solveIds.single, isNot('t1'));
      expect(c.doc.trackersForClip('source'), hasLength(1));
    });

    test('the active region is what the single-region controls act on', () {
      final (c, source, _) = harness();
      c.installTracker(slidingTracker());
      c.installTracker(secondTracker());

      // Installing makes the newest region active, which is the one the user
      // just drew.
      expect(c.trackerForClip(source)!.id, 't2');
      c.activeTrackerId = 't1';
      expect(c.trackerForClip(source)!.id, 't1');

      // A correction re-solves the active region…
      c.retrackFromPlayhead(
        source,
        quadFromRect(left: 100, top: 100, right: 500, bottom: 400),
      );
      expect(c.solveIds.last, 't1');

      // …unless the canvas names the region whose corner was grabbed.
      c.retrackFromPlayhead(
        source,
        quadFromRect(left: 100, top: 100, right: 500, bottom: 400),
        trackerId: 't2',
      );
      expect(c.solveIds.last, 't2');
    });

    test('region names are their order on the clip', () {
      final (c, _, _) = harness();
      c.installTracker(slidingTracker());
      c.installTracker(secondTracker());
      expect(c.trackerLabel(c.doc.trackerById('t1')!), 'Region 1');
      expect(c.trackerLabel(c.doc.trackerById('t2')!), 'Region 2');
    });

    test('a renamed region keeps its name, and blank goes back to the number', () {
      final (c, _, _) = harness();
      c.installTracker(slidingTracker());
      c.installTracker(secondTracker());

      c.renameTracker('t1', '  Left eye  ');
      expect(c.trackerLabel(c.doc.trackerById('t1')!), 'Left eye');
      // The number underneath is untouched: it is what the placeholder shows
      // and what the region falls back to.
      expect(c.derivedTrackerLabel(c.doc.trackerById('t1')!), 'Region 1');
      expect(c.trackerLabel(c.doc.trackerById('t2')!), 'Region 2');

      // Through the file and back.
      final reloaded = ProjectDoc.decode(c.doc.encode(touchModified: false));
      expect(reloaded.trackerById('t1')!.name, 'Left eye');
      expect(reloaded.trackerById('t2')!.name, isNull);
      // An unnamed region writes no name at all, so an untouched project is
      // byte-identical to what an older build wrote.
      expect(reloaded.trackerById('t2')!.toJson().containsKey('name'), isFalse);

      // Renaming is one undo step.
      c.undo();
      expect(c.doc.trackerById('t1')!.name, isNull);
      c.redo();
      expect(c.doc.trackerById('t1')!.name, 'Left eye');

      // Blank clears it rather than showing an empty row.
      c.renameTracker('t1', '   ');
      expect(c.doc.trackerById('t1')!.name, isNull);
      expect(c.trackerLabel(c.doc.trackerById('t1')!), 'Region 1');
    });

    test('re-tracking a named region does not rename it', () async {
      // The solve comes back from the worker, which knows nothing about names;
      // rebuilding the tracker from it must not drop what the user typed.
      final (c, source, _) = harness();
      c.installTracker(slidingTracker());
      c.renameTracker('t1', 'Sign');
      c.onSolve = (id) => slidingTracker(id: id, samples: 6);

      await c.retrackFromPlayhead(
        source,
        quadFromRect(left: 100, top: 200, right: 500, bottom: 500),
        trackerId: 't1',
      );
      expect(c.doc.trackerById('t1')!.name, 'Sign');
      expect(c.doc.trackerById('t1')!.sampleCount, 6);
    });

    test('a region knows what was dropped on it', () {
      final (c, _, overlay) = harness();
      c.installTracker(slidingTracker());
      expect(c.clipsPinnedTo('t1'), isEmpty);

      c.pinClipToTracker(overlay.id, 't1');
      expect(c.clipsPinnedTo('t1').single.id, overlay.id);
      expect(
        c.doc.assetById(c.clipsPinnedTo('t1').single.mediaId)!.name,
        'face.png',
      );

      c.unpinClip(overlay.id);
      expect(c.clipsPinnedTo('t1'), isEmpty);
    });

    test('two overlays follow two regions of the same clip', () {
      final (c, _, overlay) = harness();
      c.installTracker(slidingTracker());
      c.installTracker(secondTracker());

      final second = Clip(
        id: 'overlay2',
        trackId: overlay.trackId,
        mediaId: 'meme',
        label: 'Logo',
        start: Rt.zero(),
        duration: Rt.fromSeconds(6),
        sourceIn: Rt.zero(),
      );
      c.doc.clips.add(second);

      c.pinClipToTracker(overlay.id, 't1');
      c.pinClipToTracker(second.id, 't2');

      final a = (c.doc.clipById('overlay')!.transform!.corners!
              .evaluate(Rt.zero()) as List)
          .cast<double>();
      final b = (c.doc.clipById('overlay2')!.transform!.corners!
              .evaluate(Rt.zero()) as List)
          .cast<double>();
      expect(a[0], closeTo(100, 0.01));
      expect(b[0], closeTo(900, 0.01), reason: 'each follows its own region');
    });

    test('deleting one region leaves the other and its pin alone', () {
      final (c, _, overlay) = harness();
      c.installTracker(slidingTracker());
      c.installTracker(secondTracker());
      c.pinClipToTracker(overlay.id, 't2');

      c.deleteTracker('t1');
      expect(c.doc.trackers.map((t) => t.id), ['t2']);
      expect(
        TrackPin.fromExtra(c.doc.clipById('overlay')!.extra)?.trackerId,
        't2',
      );
      expect(c.doc.clipById('overlay')!.transform?.corners, isNotNull);
    });

    test('the confidence stripe covers every region on the clip', () {
      // A drift in one region must not be hidden by another region solving
      // cleanly over the same seconds.
      Tracker weak(String id, List<double> confidence) => Tracker(
        id: id,
        mediaId: 'video',
        sourceClipId: 'source',
        startTime: Rt.zero(),
        endTime: Rt.fromSeconds(4 / 30),
        searchQuad: const [0, 0, 10, 0, 10, 10, 0, 10],
        fps: Rt(30, 1),
        path: List<double>.filled(32, 0),
        confidence: confidence,
      );

      final (c, source, _) = harness();
      c.installTracker(weak('a', const [0.1, 1.0, 1.0, 1.0]));
      c.installTracker(weak('b', const [1.0, 1.0, 0.1, 1.0]));

      final spans = c.lowConfidenceSpansFor(source);
      expect(spans, hasLength(2));
      expect(spans[0].$1, closeTo(0, 1e-5));
      expect(spans[1].$1, closeTo(2 / 30, 1e-5));
    });
  });
}

/// Records the range a solve was asked for instead of running one, so the
/// request can be asserted without a worker.
class _ProbeController extends EditorController {
  _ProbeController(super.doc, String path) : super(path: path);

  void Function(Rt start)? onSolveRequested;
  final List<String> solveIds = [];

  /// Supplies a result, for the tests that care what installing one does.
  Tracker? Function(String trackerId)? onSolve;

  @override
  Future<Tracker?> solveTrackedRegion({
    required String trackerId,
    required Clip clip,
    required MediaAsset asset,
    required Quad searchQuad,
    required Rt start,
    required Rt end,
  }) async {
    onSolveRequested?.call(start);
    solveIds.add(trackerId);
    return onSolve?.call(trackerId);
  }
}
