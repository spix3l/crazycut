@Tags(['perf', 'fixed-runner'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/clip_transform.dart';
import 'package:crazycut_app/data/param_value.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/text_content.dart';
import 'package:crazycut_app/data/transition.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/preview_renderer.dart';

double percentile(List<double> values, double fraction) {
  if (values.isEmpty) throw ArgumentError.value(values, 'values', 'is empty');
  final sorted = [...values]..sort();
  final index = ((sorted.length - 1) * fraction).ceil();
  return sorted[index.clamp(0, sorted.length - 1)];
}

Map<String, dynamic> summarize(
  List<double> samples, {
  double budgetMs = 16.667,
}) {
  return {
    'samples': samples.length,
    'p50_ms': percentile(samples, 0.50),
    'p95_ms': percentile(samples, 0.95),
    'mean_ms': samples.reduce((a, b) => a + b) / samples.length,
    // The isolate API returns rendered frames rather than presenting them, so
    // this is the reproducible deadline-miss proxy for dropped playback frames.
    'deadline_ms': budgetMs,
    'dropped_frame_estimate': samples.where((value) => value > budgetMs).length,
  };
}

void main() {
  test(
    'percentile and deadline reporting are deterministic on ordinary CI',
    () {
      final summary = summarize([1, 4, 2, 3, 20], budgetMs: 10);
      expect(summary['p50_ms'], 3);
      expect(summary['p95_ms'], 20);
      expect(summary['dropped_frame_estimate'], 1);
    },
  );

  test(
    'fixed runner exercises the representative creator timeline',
    () async {
      if (Platform.environment['CC_PERF_RUN'] != '1') {
        markTestSkipped('set CC_PERF_RUN=1 on a fixed performance runner');
        return;
      }

      final fixtureDirectory =
          Directory(
            Platform.environment['CC_PERF_FIXTURE_DIR'] ?? '../fixtures/perf',
          ).absolute;
      final sources = [
        for (final name in ['1080p60-a.mp4', '1080p60-b.mp4', '1080p60-c.mp4'])
          File('${fixtureDirectory.path}/$name'),
      ];
      final fourK = File('${fixtureDirectory.path}/4k30.mp4');
      for (final fixture in [...sources, fourK]) {
        expect(fixture.existsSync(), isTrue, reason: 'missing ${fixture.path}');
      }

      final renderer = await PreviewRenderer.spawn();
      addTearDown(renderer.dispose);
      final scenarios = <String, dynamic>{};

      Future<List<double>> renderSamples(
        ProjectDoc doc,
        List<Rt> times, {
        int width = 1920,
        int height = 1080,
        Map<String, Uint8List> textures = const {},
        Map<String, (int, int)> textureSizes = const {},
      }) async {
        final paths = {
          for (var i = 0; i < sources.length; i++) 'm$i': sources[i].path,
        };
        paths['m4k'] = fourK.path;
        renderer.setSnapshot(doc.encode(touchModified: false));
        await renderer.render(
          time: times.first,
          width: width,
          height: height,
          mediaPaths: paths,
          textures: textures,
          textureSizes: textureSizes,
        );
        final elapsed = <double>[];
        for (final time in times) {
          final watch = Stopwatch()..start();
          final frame = await renderer.render(
            time: time,
            width: width,
            height: height,
            mediaPaths: paths,
            textures: textures,
            textureSizes: textureSizes,
          );
          watch.stop();
          expect(frame.rgba.length, width * height * 4);
          elapsed.add(watch.elapsedMicroseconds / 1000);
        }
        return elapsed;
      }

      ProjectDoc layeredDoc({int layers = 1}) {
        final doc = ProjectDoc.empty(
          '1080p60 perf',
          width: 1920,
          height: 1080,
          fps: 60,
        );
        for (var i = 0; i < layers; i++) {
          doc.media.add(
            MediaAsset(
              id: 'm$i',
              name: sources[i].uri.pathSegments.last,
              path: sources[i].path,
              type: 'video',
              duration: Rt.fromSeconds(6),
              hasAudio: true,
              width: 1920,
              height: 1080,
              fps: '60/1',
              codec: 'h264',
            ),
          );
          final track =
              i == 0
                  ? doc.videoTrack()!
                  : (Track(
                    id: 'v$i',
                    kind: 'video',
                    name: 'V${i + 1}',
                    index: i,
                  ));
          if (i > 0) doc.tracks.add(track);
          doc.clips.add(
            Clip(
              id: 'c$i',
              trackId: track.id,
              mediaId: 'm$i',
              label: 'Layer ${i + 1}',
              start: Rt.zero(),
              duration: Rt.fromSeconds(5),
              sourceIn: Rt.zero(),
              transform:
                  i == 0
                      ? null
                      : ClipTransform(
                        x: ParamValue.staticNum(i == 1 ? -220 : 220),
                        y: ParamValue.staticNum(i == 1 ? -120 : 120),
                        scale: ParamValue.staticNum(62),
                        opacity: ParamValue.staticNum(82),
                      ),
            ),
          );
        }
        return doc;
      }

      final sequential = [for (var i = 1; i <= 30; i++) Rt(i, 60)];
      scenarios['one_layer_1080p60'] = summarize(
        await renderSamples(layeredDoc(), sequential),
      );
      final threeLayers = layeredDoc(layers: 3);
      scenarios['three_layers_1080p60'] = summarize(
        await renderSamples(threeLayers, sequential),
      );

      final animated = layeredDoc(layers: 3);
      animated.clips[1].transform = ClipTransform(
        x: ParamValue(
          static: 0.0,
          keyframes: [
            {'t': '0/1', 'v': -500.0, 'interp': 'easeOut'},
            {'t': '5/1', 'v': 500.0, 'interp': 'linear'},
          ],
        ),
        rotation: ParamValue(
          static: 0.0,
          keyframes: [
            {'t': '0/1', 'v': -8.0, 'interp': 'linear'},
            {'t': '5/1', 'v': 8.0, 'interp': 'linear'},
          ],
        ),
        scale: ParamValue.staticNum(62),
      );
      scenarios['three_layers_keyframes'] = summarize(
        await renderSamples(animated, sequential),
      );

      final blurred = layeredDoc(layers: 3);
      blurred.clips.last.effects.add({
        'id': 'perf-blur',
        'type': 'gaussianBlur',
        'enabled': true,
        'params': {
          'radius': {
            'static': 20.0,
            'keyframes': [
              {'t': '0/1', 'v': 4.0, 'interp': 'linear'},
              {'t': '5/1', 'v': 32.0, 'interp': 'linear'},
            ],
          },
        },
      });
      scenarios['three_layers_animated_blur'] = summarize(
        await renderSamples(blurred, sequential),
      );

      final titled = layeredDoc(layers: 3);
      final titleTrack = Track(
        id: 'v-text',
        kind: 'video',
        name: 'V4',
        index: 3,
      );
      titled.tracks.add(titleTrack);
      titled.clips.add(
        Clip(
          id: 'title',
          trackId: titleTrack.id,
          mediaId: '',
          label: 'Benchmark title',
          start: Rt.zero(),
          duration: Rt.fromSeconds(5),
          sourceIn: Rt.zero(),
          text: TextContent(content: 'CRAZYCUT PERFORMANCE', fontSize: 84),
          transform: ClipTransform(y: ParamValue.staticNum(350)),
        ),
      );
      const textWidth = 720;
      const textHeight = 120;
      final titleBytes = Uint8List(textWidth * textHeight * 4);
      for (var y = 0; y < textHeight; y++) {
        for (var x = 0; x < textWidth; x++) {
          final offset = (y * textWidth + x) * 4;
          final visible = x % 48 < 34 && y > 18 && y < 102;
          titleBytes[offset] = 255;
          titleBytes[offset + 1] = 255;
          titleBytes[offset + 2] = 255;
          titleBytes[offset + 3] = visible ? 255 : 0;
        }
      }
      scenarios['three_layers_text'] = summarize(
        await renderSamples(
          titled,
          sequential,
          textures: {'text:title': titleBytes},
          textureSizes: const {'text:title': (textWidth, textHeight)},
        ),
      );

      final transition = layeredDoc();
      final first = transition.clips.single;
      first.duration = Rt.fromSeconds(3.5);
      transition.clips.add(
        Clip(
          id: 'incoming',
          trackId: first.trackId,
          mediaId: 'm0',
          label: 'Incoming',
          start: Rt.fromSeconds(2.5),
          duration: Rt.fromSeconds(3.5),
          sourceIn: Rt.fromSeconds(1),
        ),
      );
      transition.transitions.add(
        Transition(
          id: 'transition',
          aClipId: first.id,
          bClipId: 'incoming',
          duration: Rt.fromSeconds(1),
          type: 'crossDissolve',
        ),
      );
      scenarios['transition_1080p60'] = summarize(
        await renderSamples(transition, [
          for (var i = 0; i < 30; i++) Rt.fromSeconds(2.5 + i / 30),
        ]),
      );

      final seekTimes = [
        for (var i = 0; i < 30; i++) Rt.fromSeconds(((i * 137) % 470) / 100),
      ];
      scenarios['random_seek_three_layers'] = summarize(
        await renderSamples(threeLayers, seekTimes),
        budgetMs: 100,
      );
      final scrubTimes = [
        for (var i = 0; i < 40; i++)
          Rt.fromSeconds((i.isEven ? i : 40 - i) / 10),
      ];
      scenarios['scrub_three_layers'] = summarize(
        await renderSamples(threeLayers, scrubTimes),
        budgetMs: 100,
      );

      final fourKDoc = ProjectDoc.empty(
        '4K30 perf',
        width: 3840,
        height: 2160,
        fps: 30,
      );
      fourKDoc.media.add(
        MediaAsset(
          id: 'm4k',
          name: '4k30.mp4',
          path: fourK.path,
          type: 'video',
          duration: Rt.fromSeconds(6),
          hasAudio: true,
          width: 3840,
          height: 2160,
          fps: '30/1',
          codec: 'h264',
        ),
      );
      fourKDoc.clips.add(
        Clip(
          id: 'c4k',
          trackId: fourKDoc.videoTrack()!.id,
          mediaId: 'm4k',
          label: '4K source',
          start: Rt.zero(),
          duration: Rt.fromSeconds(5),
          sourceIn: Rt.zero(),
        ),
      );
      scenarios['4k30_source_to_1080p'] = summarize(
        await renderSamples(fourKDoc, seekTimes.take(15).toList()),
        budgetMs: 33.334,
      );

      final worker = File(
        Platform.isWindows
            ? '../engine/build/Release/crazycut_worker.exe'
            : '../engine/build/crazycut_worker',
      );
      expect(
        worker.existsSync(),
        isTrue,
        reason: 'missing ${worker.absolute.path}',
      );
      final temp = Directory.systemTemp.createTempSync('crazycut-perf-export-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final exportDoc = layeredDoc(layers: 3);
      for (final clip in exportDoc.clips) {
        clip.duration = Rt.fromSeconds(1);
      }
      final output = '${temp.path}/three-layer.mp4';
      final jobFile = File('${temp.path}/job.json');
      jobFile.writeAsStringSync(
        jsonEncode({
          'type': 'timeline',
          'document': jsonDecode(exportDoc.encode(touchModified: false)),
          'media': {
            for (var i = 0; i < sources.length; i++) 'm$i': sources[i].path,
          },
          'output': output,
          'startSec': 0.0,
          'endSec': 1.0,
          'video': {
            'codec': 'h264',
            'crf': 28,
            'preset': 'veryfast',
            'maxWidth': 1920,
            'maxHeight': 1080,
            'hardware': false,
          },
          'audio': null,
          'faststart': true,
        }),
      );
      final exportWatch = Stopwatch()..start();
      final result = await Process.run(worker.path, ['--job', jobFile.path]);
      exportWatch.stop();
      expect(result.exitCode, 0, reason: '${result.stderr}\n${result.stdout}');
      expect(File(output).existsSync(), isTrue);
      final exportSeconds = exportWatch.elapsedMicroseconds / 1000000;
      final frameMs = exportSeconds * 1000 / 60;
      scenarios['export_three_layers_1080p60'] = {
        ...summarize([frameMs]),
        'wall_seconds': exportSeconds,
        'source_seconds': 1.0,
        'realtime_factor': 1 / exportSeconds,
        'output_bytes': File(output).lengthSync(),
      };

      final reportPath =
          Platform.environment['CC_PERF_REPORT'] ?? '../build/perf/report.json';
      final reportFile = File(reportPath).absolute;
      reportFile.parent.createSync(recursive: true);
      reportFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'schema': 'crazycut-perf-report@1',
          'captured_at': DateTime.now().toUtc().toIso8601String(),
          'metadata': {
            'fixture_manifest': '${fixtureDirectory.path}/manifest.json',
            'source_resolution': ['1920x1080@60', '3840x2160@30'],
            'output_resolution': '1920x1080',
            'proxy': Platform.environment['CC_PERF_PROXY'] == '1',
            'acceleration':
                Platform.environment['CC_PERF_ACCELERATION'] ?? 'software',
            'build_type': 'Release',
          },
          'process': {
            'peak_rss_bytes': ProcessInfo.maxRss,
            'current_rss_bytes': ProcessInfo.currentRss,
          },
          'scenarios': scenarios,
        }),
      );

      // A performance run is observational. Fixed-runner regression policy is
      // applied by perf_report.py against a same-machine accepted baseline.
      expect(scenarios, contains('three_layers_1080p60'));
      expect(
        math.max(ProcessInfo.maxRss, ProcessInfo.currentRss),
        greaterThan(0),
      );
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
