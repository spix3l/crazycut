import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/clip_transform.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/transcript.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/shorts_service.dart';
import 'temp_dir.dart';

ShortCandidate candidate(
  double start,
  double end, {
  String title = 'A moment',
  double confidence = 0.5,
}) => ShortCandidate(
  startSec: start,
  endSec: end,
  title: title,
  hook: 'hook',
  reason: 'reason',
  confidence: confidence,
);

Transcript transcriptWith(List<(double, double)> spans) => Transcript(
  language: 'en',
  durationSeconds: 600,
  segments: [
    for (final s in spans)
      TranscriptSegment(start: s.$1, end: s.$2, text: 'words'),
  ],
);

ProjectDoc sourceDoc() {
  final doc = ProjectDoc.empty('Stream VOD', width: 1920, height: 1080, fps: 30);
  doc.media.add(
    MediaAsset(
      id: 'asset-1',
      name: 'vod.mp4',
      path: '/tmp/vod.mp4',
      type: 'video',
      duration: Rt.fromSeconds(600),
      hasAudio: true,
      hash: 'sha256:abc',
      width: 1920,
      height: 1080,
    ),
  );
  return doc;
}

void main() {
  final service = ShortsService();

  group('sanitizeCandidates (SHT-6)', () {
    test('keeps a well-formed candidate', () {
      final kept = service.sanitizeCandidates([
        candidate(10, 40),
      ], mediaDurationSec: 600);
      expect(kept.length, 1);
      expect(kept.single.startSec, 10);
      expect(kept.single.endSec, 40);
    });

    test('clamps a hallucinated timestamp past the end of the media', () {
      final kept = service.sanitizeCandidates([
        candidate(580, 900),
      ], mediaDurationSec: 600);
      expect(kept.single.endSec, 600);
    });

    test('drops anything shorter than the minimum after clamping', () {
      // Clamping pulls the end back to 600, leaving 2 s — too short to be a short.
      final kept = service.sanitizeCandidates([
        candidate(598, 900),
      ], mediaDurationSec: 600);
      expect(kept, isEmpty);
    });

    test('truncates anything longer than the maximum', () {
      final kept = service.sanitizeCandidates([
        candidate(0, 500),
      ], mediaDurationSec: 600);
      expect(kept.single.durationSec, 180);
    });

    test('repairs a reversed range rather than discarding it', () {
      final kept = service.sanitizeCandidates([
        candidate(90, 30),
      ], mediaDurationSec: 600);
      expect(kept.single.startSec, 30);
      expect(kept.single.endSec, 90);
    });

    test('resolves overlaps in favour of the higher confidence', () {
      final kept = service.sanitizeCandidates([
        candidate(10, 60, title: 'weak', confidence: 0.2),
        candidate(30, 80, title: 'strong', confidence: 0.9),
      ], mediaDurationSec: 600);
      expect(kept.length, 1);
      expect(kept.single.title, 'strong');
    });

    test('keeps adjacent but non-overlapping candidates', () {
      final kept = service.sanitizeCandidates([
        candidate(10, 40),
        candidate(40, 70),
      ], mediaDurationSec: 600);
      expect(kept.length, 2);
    });

    test('caps the list and keeps the strongest', () {
      final many = [
        for (var i = 0; i < 30; i++)
          candidate(i * 20.0, i * 20.0 + 15, confidence: i / 30),
      ];
      final kept = service.sanitizeCandidates(many, mediaDurationSec: 1000);
      expect(kept.length, 12);
      // The cap must keep the best, not the first twelve it happened to see.
      expect(kept.every((c) => c.confidence >= 0.5), isTrue);
    });

    test('returns them in timeline order', () {
      final kept = service.sanitizeCandidates([
        candidate(200, 240, confidence: 0.2),
        candidate(10, 50, confidence: 0.9),
      ], mediaDurationSec: 600);
      expect(kept.map((c) => c.startSec), [10, 200]);
    });

    test('snaps onto speech boundaries when a transcript is available', () {
      final kept = service.sanitizeCandidates(
        [candidate(10.4, 39.6)],
        mediaDurationSec: 600,
        transcript: transcriptWith([(10.0, 20.0), (20.0, 40.0)]),
      );
      expect(kept.single.startSec, 10.0);
      expect(kept.single.endSec, 40.0);
    });

    test('refuses a snap that would break the minimum length', () {
      final kept = service.sanitizeCandidates(
        [candidate(10, 16)],
        mediaDurationSec: 600,
        // Snapping both ends here would collapse the range.
        transcript: transcriptWith([(12.0, 13.0)]),
      );
      expect(kept.single.durationSec, greaterThanOrEqualTo(5));
    });

    test('an empty list in gives an empty list out, not an error', () {
      expect(service.sanitizeCandidates([], mediaDurationSec: 600), isEmpty);
    });
  });

  group('nudgeCandidate (SHT-9)', () {
    const rules = ShortsRules();

    test('moves the in-point', () {
      final moved = nudgeCandidate(
        candidate(30, 60),
        startDelta: -2,
        mediaDurationSec: 600,
        rules: rules,
      );
      expect(moved.startSec, 28);
      expect(moved.endSec, 60);
    });

    test('will not nudge past the start of the media', () {
      final moved = nudgeCandidate(
        candidate(1, 40),
        startDelta: -5,
        mediaDurationSec: 600,
        rules: rules,
      );
      expect(moved.startSec, 0);
    });

    test('refuses a nudge that would go under the minimum', () {
      final original = candidate(30, 36);
      final moved = nudgeCandidate(
        original,
        startDelta: 5,
        mediaDurationSec: 600,
        rules: rules,
      );
      expect(moved.startSec, original.startSec);
    });
  });

  group('snapToFrame', () {
    test('lands on a frame boundary', () {
      expect(snapToFrame(1.017, 30), closeTo(1.0 + 1 / 30, 1e-9));
    });

    test('passes through when the frame rate is unknown', () {
      expect(snapToFrame(1.017, 0), 1.017);
    });
  });

  group('createProject (SHT-12 … SHT-16)', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('cc-shorts'));
    tearDown(() => deleteTempDir(temp));

    Future<ProjectDoc> create(ShortCandidate c, {ProjectDoc? source}) async {
      final doc = source ?? sourceDoc();
      final file = await service.createProject(
        c,
        source: doc,
        asset: doc.media.single,
        sourceProjectPath: '${temp.path}/Stream VOD.crazycut',
      );
      return ProjectDoc.decode(await file.readAsString());
    }

    test('creates a 1080x1920 project at the source frame rate', () async {
      final made = await create(candidate(30, 75));
      expect(made.settings.width, 1080);
      expect(made.settings.height, 1920);
      expect(made.settings.fpsValue, 30);
    });

    test('holds exactly one video clip and one linked audio clip', () async {
      final made = await create(candidate(30, 75));
      final video = made.clips.where(
        (c) => made.trackById(c.trackId)!.kind == 'video',
      );
      final audio = made.clips.where(
        (c) => made.trackById(c.trackId)!.kind == 'audio',
      );
      expect(video.length, 1);
      expect(audio.length, 1);
      expect(video.single.linkedGroup, isNotNull);
      expect(video.single.linkedGroup, audio.single.linkedGroup);
    });

    test('places the clip at zero with the candidate range', () async {
      final made = await create(candidate(30, 75));
      final clip = made.clips.first;
      expect(clip.start.seconds, 0);
      expect(clip.duration.seconds, closeTo(45, 1e-6));
      expect(clip.sourceIn.seconds, closeTo(30, 1e-6));
    });

    test('uses crop-to-fill framing so 16:9 fills the vertical canvas', () async {
      final made = await create(candidate(30, 75));
      final video = made.clips.firstWhere(
        (c) => made.trackById(c.trackId)!.kind == 'video',
      );
      expect(video.transform, isA<ClipTransform>());
      expect(video.transform!.framing, 'fill');
    });

    test('reuses the source asset id and hash so caches stay warm', () async {
      final source = sourceDoc();
      final made = await create(candidate(30, 75), source: source);
      expect(made.media.single.id, source.media.single.id);
      expect(made.media.single.hash, source.media.single.hash);
      expect(made.media.single.path, source.media.single.path);
    });

    test('names the file after the source project and the title', () async {
      final doc = sourceDoc();
      final file = await service.createProject(
        candidate(30, 75, title: 'The good bit'),
        source: doc,
        asset: doc.media.single,
        sourceProjectPath: '${temp.path}/Stream VOD.crazycut',
      );
      expect(file.path, endsWith('Stream VOD — The good bit.crazycut'));
    });

    test('falls back to a timecode when the title is unusable', () async {
      final doc = sourceDoc();
      final file = await service.createProject(
        candidate(90, 130, title: '   '),
        source: doc,
        asset: doc.media.single,
        sourceProjectPath: '${temp.path}/Stream VOD.crazycut',
      );
      expect(file.path, endsWith('Stream VOD — 01.30.crazycut'));
    });

    test('strips characters that cannot be in a filename', () async {
      final doc = sourceDoc();
      final file = await service.createProject(
        candidate(30, 75, title: 'a/b:c*d?"e'),
        source: doc,
        asset: doc.media.single,
        sourceProjectPath: '${temp.path}/Stream VOD.crazycut',
      );
      expect(file.path.contains('/a/b'), isFalse);
      expect(File(file.path).existsSync(), isTrue);
    });

    test('suffixes a duplicate rather than overwriting it', () async {
      final doc = sourceDoc();
      Future<File> make() => service.createProject(
        candidate(30, 75, title: 'Same'),
        source: doc,
        asset: doc.media.single,
        sourceProjectPath: '${temp.path}/Stream VOD.crazycut',
      );
      final first = await make();
      final second = await make();
      expect(first.path, isNot(second.path));
      expect(second.path, endsWith('(1).crazycut'));
      expect(first.existsSync() && second.existsSync(), isTrue);
    });

    test('omits the audio clip when the source has no sound', () async {
      final doc = ProjectDoc.empty('Silent', width: 1920, height: 1080, fps: 30);
      doc.media.add(
        MediaAsset(
          id: 'a',
          name: 'silent.mp4',
          path: '/tmp/silent.mp4',
          type: 'video',
          duration: Rt.fromSeconds(600),
          hasAudio: false,
        ),
      );
      final made = await create(candidate(10, 40), source: doc);
      expect(made.clips.length, 1);
    });

    test('the written project loads back with nothing to repair', () async {
      // An agent-authored or model-derived project must satisfy the same
      // invariants as a hand-made one (SHT acceptance criterion 2).
      final report = RepairReport();
      final doc = sourceDoc();
      final file = await service.createProject(
        candidate(30, 75),
        source: doc,
        asset: doc.media.single,
        sourceProjectPath: '${temp.path}/Stream VOD.crazycut',
      );
      final reloaded = ProjectDoc.decode(
        await file.readAsString(),
        report: report,
      );
      expect(report.issues, isEmpty);
      expect(reloaded.clips.length, 2);
      expect(reloaded.settings.height, 1920);
    });
  });
}
