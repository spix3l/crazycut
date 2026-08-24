import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/text_content.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/features/export/presentation/widgets/export_queue_panel.dart';
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

    test('software size estimate is calibrated to CRF output', () {
      final bytes = estimateExportBytes(
        preset: ExportPreset.youtube1080,
        quality: ExportQuality.high,
        width: 1920,
        height: 1080,
        fps: 30,
        seconds: 60,
      );
      // About 20 MB/min for ordinary 1080p30 footage, rather than the old
      // fixed-bitrate estimate of roughly 54 MB/min.
      expect(bytes, inInclusiveRange(18 * 1024 * 1024, 24 * 1024 * 1024));
    });

    test('hardware estimate mirrors its higher target bitrate', () {
      final software = estimateExportBytes(
        preset: ExportPreset.youtube1080,
        quality: ExportQuality.high,
        width: 1920,
        height: 1080,
        fps: 30,
        seconds: 60,
      );
      final hardware = estimateExportBytes(
        preset: ExportPreset.youtube1080,
        quality: ExportQuality.high,
        width: 1920,
        height: 1080,
        fps: 30,
        seconds: 60,
        hardware: true,
      );
      expect(hardware, greaterThan(software * 3));
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

  group('time remaining', () {
    ExportJob runningJob({required int totalFrames}) {
      final job = ExportJob(
        id: 'j',
        name: 'out.mp4',
        outputPath: '/tmp/out.mp4',
        spec: const {},
        totalFrames: totalFrames,
        durationSeconds: 10,
      );
      job.state = ExportState.running;
      job.startedAt = DateTime.now().subtract(const Duration(seconds: 10));
      return job;
    }

    test('the rate follows recent frames, not the whole job', () {
      final job = runningJob(totalFrames: 1000);
      // Ten seconds of startup with nothing encoded, then a steady 30fps: the
      // ETA should describe the 30fps, not the average that includes the wait.
      final start = DateTime.now();
      job.observeProgress(start);
      for (var i = 1; i <= 4; i++) {
        job.framesDone = i * 30;
        job.observeProgress(start.add(Duration(seconds: i)));
      }
      expect(job.fps, closeTo(30, 2));
      // 880 frames left at ~30fps ≈ 29s, not the ~2.5fps a lifetime average
      // would have reported.
      expect(job.etaSeconds, closeTo(29, 3));
    });

    test('an unknown frame count still estimates from the fraction done', () {
      final job = runningJob(totalFrames: 0);
      job.progress = 0.25;  // a quarter done after ten seconds
      expect(job.etaSeconds, closeTo(30, 2));
      expect(job.statusLine, contains('left'));
    });

    test('no estimate before there is anything to estimate from', () {
      final job = runningJob(totalFrames: 0);
      expect(job.etaSeconds, isNull);
      expect(job.statusLine, isNot(contains('left')));
    });

    test('remaining time is phrased at the coarseness it deserves', () {
      expect(ExportJob.formatRemaining(4), 'a few seconds');
      expect(ExportJob.formatRemaining(42), '40s');
      expect(ExportJob.formatRemaining(90), '1m 30s');
      expect(ExportJob.formatRemaining(20 * 60), '20m');
      expect(ExportJob.formatRemaining(85 * 60), '1h 25m');
      expect(ExportJob.formatRemaining(2 * 3600), '2h');
    });

    test('the worker frame count replaces a wrong estimate', () {
      final job = runningJob(totalFrames: 0);
      expect(job.etaSeconds, isNull, reason: 'nothing to divide by yet');
      job.totalFrames = 900;  // what the worker reports on start
      job.framesDone = 300;
      job.fps = 30;
      expect(job.etaSeconds, closeTo(20, 0.1));
    });
  });

  group('the running card', () {
    testWidgets('shows one progress reading, with the time left', (
      tester,
    ) async {
      final job = ExportJob(
        id: 'j',
        name: 'building-a-daw [YouTube 1080p].mp4',
        outputPath: '/tmp/out.mp4',
        spec: const {},
        totalFrames: 1000,
        durationSeconds: 33,
      );
      job.state = ExportState.running;
      job.startedAt = DateTime.now();
      job.framesDone = 100;
      job.progress = 0.1;
      job.fps = 30;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ExportJobCard(job: job, service: ExportService.instance),
        ),
      );

      // 900 frames left at 30fps.
      expect(find.textContaining('30s left'), findsOneWidget);
      expect(find.textContaining('10%'), findsOneWidget);
      // The bar is the only progress indicator: no ring alongside it.
      expect(find.byType(CustomPaint), findsNothing);
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

    test(
      'renders text pixels into the final file',
      () async {
        final ffmpeg = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
        ProcessResult availability;
        try {
          availability = Process.runSync(ffmpeg, ['-version']);
        } on ProcessException {
          markTestSkipped('ffmpeg CLI missing');
          return;
        }
        if (availability.exitCode != 0) {
          markTestSkipped('ffmpeg CLI missing');
          return;
        }
        final doc = ProjectDoc.empty(
          'Text export',
          width: 320,
          height: 180,
          fps: 30,
        );
        doc.clips.add(
          Clip(
            id: 'title',
            trackId: doc.videoTrack()!.id,
            mediaId: '',
            label: 'Visible title',
            start: Rt.zero(),
            duration: Rt.fromSeconds(1),
            sourceIn: Rt.zero(),
            text: TextContent(content: 'EXPORTED', fontSize: 72),
          ),
        );

        final output = '${temp.path}/text.mp4';
        final job = ExportService.instance.submit(
          doc: doc,
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
        final decoded = await Process.run(
            ffmpeg,
            [
              '-v',
              'error',
              '-ss',
              '0.5',
              '-i',
              output,
              '-frames:v',
              '1',
              '-f',
              'rawvideo',
              '-pix_fmt',
              'gray',
              '-',
            ],
            stdoutEncoding: null);
        expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
        final pixels = decoded.stdout as List<int>;
        expect(
          pixels.any((value) => value > 32),
          isTrue,
          reason:
              'max=${pixels.fold<int>(0, (a, b) => a > b ? a : b)} log=${job.log} spec=${job.spec['textTextures']}',
        );
        expect(
          (job.spec['textTextures'] as Map<String, dynamic>).containsKey(
            'text:title',
          ),
          isTrue,
        );
        final texture = ((job.spec['textTextures'] as Map<String, dynamic>)[
                'text:title'] as Map<String, dynamic>);
        final variants = texture['variants'] as List<dynamic>;
        expect(
          variants.every((value) =>
              !File((value as Map<String, dynamic>)['path'] as String)
                  .existsSync()),
          isTrue,
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

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
