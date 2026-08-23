import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/export_presets.dart';
import 'package:crazycut_app/state/export_service.dart';

ProjectDoc sampleDoc({int width = 640, int height = 360}) {
  final doc = ProjectDoc.empty('Demo Project', width: width, height: height, fps: 30);
  doc.media.add(MediaAsset(
    id: 'a1',
    name: 'sample.mp4',
    path: File('../fixtures/media/sample.mp4').absolute.path,
    type: 'video',
    duration: Rt.fromSeconds(10),
    hasAudio: true,
  ));
  doc.clips.add(Clip(
    id: 'c1',
    trackId: doc.videoTrack()!.id,
    mediaId: 'a1',
    label: 'clip',
    start: Rt.zero(),
    duration: Rt.fromSeconds(2),
    sourceIn: Rt.zero(),
  ));
  return doc;
}

void main() {
  // The export service talks to the host over a method channel.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('presets (EXP-2/3)', () {
    test('output size fits inside the preset box without upscaling', () {
      final portrait = SequenceSettings(width: 1080, height: 1920, fps: '30/1');
      expect(ExportPreset.shorts.outputSize(portrait), (1080, 1920));

      final landscape = SequenceSettings(width: 3840, height: 2160, fps: '30/1');
      expect(ExportPreset.youtube1080.outputSize(landscape), (1920, 1080));
      // A 4K preset never blows a 1080p sequence up.
      final hd = SequenceSettings(width: 1920, height: 1080, fps: '30/1');
      expect(ExportPreset.youtube4k.outputSize(hd), (1920, 1080));
    });

    test('output dimensions stay even', () {
      final odd = SequenceSettings(width: 1281, height: 723, fps: '30/1');
      final (w, h) = ExportPreset.youtube1080.outputSize(odd);
      expect(w.isEven, isTrue);
      expect(h.isEven, isTrue);
    });

    test('default filename carries the project and preset', () {
      expect(
        ExportPreset.youtube1080.defaultFilename('Beauty Routine'),
        'Beauty Routine [YouTube 1080p].mp4',
      );
      expect(ExportPreset.proresMaster.defaultFilename('Demo'),
          'Demo [Master (ProRes)].mov');
    });

    test('quality rungs map to sensible encoder knobs', () {
      expect(ExportQuality.draft.crf, greaterThan(ExportQuality.master.crf));
      expect(ExportQuality.web.preset, 'fast');
    });
  });

  group('queue', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('cc_export'));
    tearDown(() {
      ExportService.instance.cancelAll();
      ExportService.instance.clearFinished();
      temp.deleteSync(recursive: true);
    });

    test('an existing filename gets a suffix rather than being overwritten', () {
      final path = '${temp.path}/out.mp4';
      File(path).writeAsStringSync('x');
      final unique = ExportService.uniquePath(path);
      expect(unique, '${temp.path}/out (1).mp4');
      File(unique).writeAsStringSync('x');
      expect(ExportService.uniquePath(path), '${temp.path}/out (2).mp4');
    });

    test('the job carries a snapshot: later edits do not change it', () {
      final doc = sampleDoc();
      final service = ExportService.instance;
      final job = service.submit(
        doc: doc,
        preset: ExportPreset.youtube1080,
        outputPath: '${temp.path}/snapshot.mp4',
        quality: ExportQuality.draft,
      );
      // Edit the document after submitting.
      doc.clips.first.duration = Rt.fromSeconds(9);
      doc.name = 'Renamed';

      final clips = (job.spec['document'] as Map<String, dynamic>)['clips']
          as List<dynamic>;
      expect((clips.first as Map<String, dynamic>)['duration'], '2/1');
      expect((job.spec['document'] as Map<String, dynamic>)['name'], 'Demo Project');
      service.cancel(job.id);
    });

    test('the spec matches the preset and options chosen', () {
      final service = ExportService.instance;
      final job = service.submit(
        doc: sampleDoc(),
        preset: ExportPreset.proresMaster,
        outputPath: '${temp.path}/master.mov',
        quality: ExportQuality.master,
        hardware: true,
        loudness: true,
        rangeStart: Rt.fromSeconds(1),
        rangeEnd: Rt.fromSeconds(2),
      );
      final video = job.spec['video'] as Map<String, dynamic>;
      final audio = job.spec['audio'] as Map<String, dynamic>;
      expect(video['codec'], 'prores');
      expect(video['hardware'], isTrue);
      expect(audio['codec'], 'pcm');
      expect(audio['loudnessLufs'], -14.0);
      expect(job.spec['startSec'], 1.0);
      expect(job.spec['endSec'], 2.0);
      expect(job.spec['faststart'], isFalse);
      expect(job.totalFrames, 30);
      service.cancel(job.id);
    });

    test('leveling and exposure matching ride the spec only when asked', () {
      final service = ExportService.instance;
      final off = service.submit(
        doc: sampleDoc(),
        preset: ExportPreset.youtube1080,
        outputPath: '${temp.path}/normalize-off.mp4',
        quality: ExportQuality.draft,
      );
      expect(
        (off.spec['audio'] as Map<String, dynamic>).containsKey('levelClips'),
        isFalse,
      );
      expect(
        (off.spec['video'] as Map<String, dynamic>)
            .containsKey('matchExposure'),
        isFalse,
      );
      service.cancel(off.id);

      final on = service.submit(
        doc: sampleDoc(),
        preset: ExportPreset.youtube1080,
        outputPath: '${temp.path}/normalize-on.mp4',
        quality: ExportQuality.draft,
        loudness: true,
        levelClips: true,
        matchExposure: true,
      );
      // AUD-16 / EXP-15 compose with the master normalize (EXP-7), they do
      // not replace it.
      final audio = on.spec['audio'] as Map<String, dynamic>;
      final video = on.spec['video'] as Map<String, dynamic>;
      expect(audio['loudnessLufs'], -14.0);
      expect(audio['levelClips'], isTrue);
      expect(video['matchExposure'], isTrue);
      service.cancel(on.id);
    });

    test('cancelling removes the job from the active set', () {
      final service = ExportService.instance;
      final job = service.submit(
        doc: sampleDoc(),
        preset: ExportPreset.youtube1080,
        outputPath: '${temp.path}/cancelled.mp4',
        quality: ExportQuality.draft,
      );
      expect(service.activeCount, 1);
      service.cancel(job.id);
      expect(job.state, ExportState.cancelled);
      expect(service.activeCount, 0);
    });
  });

  group('end to end', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('cc_export_e2e'));
    tearDown(() {
      ExportService.instance.clearFinished();
      temp.deleteSync(recursive: true);
    });

    test('renders a real file, with a sidecar and no partials left behind',
        () async {
      if (!File('../fixtures/media/sample.mp4').existsSync()) {
        markTestSkipped('fixture media missing');
        return;
      }
      final service = ExportService.instance;
      final output = '${temp.path}/e2e.mp4';
      final job = service.submit(
        doc: sampleDoc(),
        preset: ExportPreset.youtube1080,
        outputPath: output,
        quality: ExportQuality.draft,
      );

      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (job.state == ExportState.queued ||
          job.state == ExportState.running) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(job.state, ExportState.completed, reason: job.error ?? '');
      expect(File(output).existsSync(), isTrue);
      expect(File(output).lengthSync(), greaterThan(1000));
      // EXP-13: the .part is renamed, not left alongside the result.
      expect(File('$output.part').existsSync(), isFalse);
      expect(File('$output.job.json').existsSync(), isFalse);

      // EXP-14: a sidecar records what produced the file.
      final sidecar = File('$output.log.json');
      expect(sidecar.existsSync(), isTrue);
      final report = jsonDecode(sidecar.readAsStringSync())
          as Map<String, dynamic>;
      expect(report['state'], 'completed');
      expect(report['frames'], 60);
      expect((report['settings'] as Map<String, dynamic>).containsKey('document'),
          isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a job that cannot run fails cleanly and leaves no partial', () async {
      final service = ExportService.instance;
      // A directory that does not exist: the worker cannot open the output.
      final output = '${temp.path}/missing-dir/out.mp4';
      final job = service.submit(
        doc: sampleDoc(),
        preset: ExportPreset.youtube1080,
        outputPath: output,
        quality: ExportQuality.draft,
      );

      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (job.state == ExportState.queued ||
          job.state == ExportState.running) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(job.state, ExportState.failed);
      expect(job.error, isNotNull);
      expect(File('$output.part').existsSync(), isFalse);
      // A job that cannot even be written out is not retried — retrying is for
      // encode failures that might be transient (EXP-11), not for a path that
      // does not exist.
      expect(job.retried, isFalse);
      expect(service.diagnosticsFor(job), contains('state: failed'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
