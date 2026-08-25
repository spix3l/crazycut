/// End-to-end: real transcription through the worker, a real HTTP round-trip
/// to a provider, and a real 9:16 project on disk.
///
/// Everything here is the shipping code path — the only stand-in is the model
/// server, which is a local socket speaking the OpenAI-compatible shape. That
/// is the point: the feature must not care which endpoint answers.
///
/// Needs the engine built and a speech model:
///   CC_WHISPER_MODEL=/path/to/ggml-tiny.en.bin flutter test test/shorts_e2e_test.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/ai/ai_settings.dart';
import 'package:crazycut_app/ai/providers/openai_compatible_provider.dart';
import 'package:crazycut_app/data/media_cache.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/transcript.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/shorts_service.dart';
import 'package:crazycut_app/state/speech_model.dart';
import 'package:crazycut_app/state/transcription_service.dart';

/// Restores real sockets inside the end-to-end test. The base class already
/// produces genuine clients, so an empty subclass is exactly the escape hatch.
class _RealNetworking extends HttpOverrides {}

/// A local server speaking `/v1/chat/completions`, standing in for whichever
/// endpoint the user configured.
Future<(HttpServer, List<Map<String, dynamic>>)> startFakeProvider(
  Object candidatesPayload,
) async {
  final seen = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = await utf8.decoder.bind(request).join();
    seen.add(jsonDecode(body) as Map<String, dynamic>);
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'model': 'fake-1',
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': jsonEncode(candidatesPayload),
              },
              'finish_reason': 'stop',
            },
          ],
          'usage': {'prompt_tokens': 100, 'completion_tokens': 50},
        }),
      );
    await request.response.close();
  });
  return (server, seen);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final modelPath = Platform.environment['CC_WHISPER_MODEL'];

  test('a recording becomes a reviewed 9:16 project', () async {
    // flutter_test installs HttpOverrides that answer every request with a
    // 400 so unit tests cannot reach the network. This test deliberately does
    // reach one — a loopback socket it started itself — so real networking is
    // restored inside this zone only.
    // The base HttpOverrides builds real clients; constructing one inside a
    // createHttpClient callback would resolve back through the override and
    // recurse.
    await HttpOverrides.runWithHttpOverrides(
      () => _endToEnd(modelPath),
      _RealNetworking(),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('with no provider configured nothing reaches the network', () async {
    final settings = AiSettings(
      storageDirOverride: await Directory.systemTemp.createTemp('cc-noai'),
    );
    await settings.load();
    expect(settings.configured, isFalse);
    expect(settings.createProvider(), isNull);
  });

  test('a transcript round-trips through the cache format', () {
    const original = Transcript(
      language: 'en',
      durationSeconds: 12.5,
      segments: [
        TranscriptSegment(start: 0, end: 2.5, text: 'hello there'),
        TranscriptSegment(start: 2.5, end: 6, text: 'second line'),
      ],
    );
    final decoded = Transcript.decode(original.encode());
    expect(decoded, isNotNull);
    expect(decoded!.segments.length, 2);
    expect(decoded.segments.last.text, 'second line');
    expect(decoded.toTimedText(), contains('[00:00 - 00:03]'));
  });
}

/// Builds a clip with actual speech in it. The checked-in fixtures are tone
/// and colour bars — correct behaviour there is "no speech found", which is a
/// different test. Generated rather than checked in, like every other fixture
/// in this repo.
Future<File?> _makeSpeechClip(Directory dir) async {
  final aiff = File('${dir.path}/speech.aiff');
  final mp4 = File('${dir.path}/speech.mp4');
  const line =
      'Here is the thing nobody tells you about editing. '
      'The first cut is never the one you keep. '
      'Watch what happens when I change just one setting.';

  final say = await Process.run('say', ['-o', aiff.path, line]);
  if (say.exitCode != 0 || !aiff.existsSync()) return null;

  final ffmpeg = await Process.run('ffmpeg', [
    '-y', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'color=c=navy:s=640x360:r=30',
    '-i', aiff.path,
    '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-shortest',
    mp4.path,
  ]);
  if (ffmpeg.exitCode != 0 || !mp4.existsSync()) return null;
  return mp4;
}

Future<void> _endToEnd(String? modelPath) async {
  {
    if (modelPath == null) {
      markTestSkipped('set CC_WHISPER_MODEL to run the end-to-end path');
      return;
    }
    final media = await Directory.systemTemp.createTemp('cc-e2e-media');
    final fixture = await _makeSpeechClip(media);
    if (fixture == null) {
      markTestSkipped('needs `say` and `ffmpeg` to generate a speech clip');
      media.deleteSync(recursive: true);
      return;
    }

    // --- the source recording -------------------------------------------
    final doc = ProjectDoc.empty('E2E VOD', width: 1920, height: 1080, fps: 30);
    final asset = MediaAsset(
      id: 'asset-e2e',
      name: 'sample.mp4',
      path: fixture.path,
      type: 'video',
      duration: Rt.fromSeconds(8),
      hasAudio: true,
      hash: 'sha256:e2e-${DateTime.now().microsecondsSinceEpoch}',
      width: 1920,
      height: 1080,
    );
    doc.media.add(asset);

    // --- 1. transcribe locally, through the real worker ------------------
    final models = SpeechModelStore.instance;
    final installed = await models.fileFor(speechModelById('tiny.en'));
    await installed.parent.create(recursive: true);
    await File(modelPath).copy(installed.path);

    final transcription = TranscriptionService()..modelIdOverride = 'tiny.en';
    final transcript = await transcription.ensure(asset);

    expect(
      transcript,
      isNotNull,
      reason:
          'transcription failed: '
          '${transcription.jobFor(asset.id)?.error}',
    );
    expect(transcription.stateOf(asset.id), TranscriptionState.ready);

    // Second call must come straight from the cache (AI-21).
    final again = await transcription.ensure(asset);
    expect(again, isNotNull);
    expect(await MediaCache.instance.hasTranscript(asset), isTrue);

    // --- 2. propose, over a real HTTP round-trip -------------------------
    final (server, seen) = await startFakeProvider({
      'candidates': [
        {
          'startSec': 0.5,
          'endSec': 7.5,
          'title': 'The good bit',
          'hook': 'Here is the thing',
          'reason': 'It stands alone.',
          'confidence': 0.9,
        },
        {
          // Overlaps the first and is weaker: must be dropped (SHT-6).
          'startSec': 5.0,
          'endSec': 7.9,
          'title': 'Overlapping',
          'hook': 'x',
          'reason': 'y',
          'confidence': 0.3,
        },
        {
          // Past the end of the media, and too short once clamped: dropped.
          'startSec': 7.9,
          'endSec': 400.0,
          'title': 'Hallucinated',
          'hook': 'x',
          'reason': 'y',
          'confidence': 0.8,
        },
      ],
    });
    // Closed at the end of the run rather than via addTearDown, which is
    // only valid directly inside a test body.

    final settings = AiSettings(storageDirOverride: await MediaCache.instance.dir());
    await settings.save(
      AiConfig(
        providerId: 'openai-compatible',
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        model: 'fake-1',
        // The stand-in does not enforce schemas, so this run exercises the
        // core's degradation path rather than the easy one (AI-9).
        capabilityOverrides: const {'jsonSchema': false, 'tools': false},
      ),
      apiKey: 'test-key',
    );

    final provider = settings.createProvider();
    expect(provider, isA<OpenAiCompatibleProvider>());

    final service = ShortsService();
    final candidates = await service.propose(provider!, transcript!);

    expect(seen, hasLength(1), reason: 'one request, not an agent loop');
    expect(
      jsonEncode(seen.single['messages']),
      contains('JSON Schema'),
      reason: 'the schema was taught in the prompt, since the endpoint '
          'cannot enforce one',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.title, 'The good bit');
    expect(candidates.single.startSec, greaterThanOrEqualTo(0));
    expect(candidates.single.endSec, lessThanOrEqualTo(8.1));

    // --- 3. accept: a real 9:16 project on disk --------------------------
    final temp = await Directory.systemTemp.createTemp('cc-e2e');

    final file = await service.createProject(
      candidates.single,
      source: doc,
      asset: asset,
      sourceProjectPath: '${temp.path}/E2E VOD.crazycut',
    );

    expect(file.existsSync(), isTrue);
    expect(file.path, endsWith('E2E VOD — The good bit.crazycut'));

    final report = RepairReport();
    final made = ProjectDoc.decode(await file.readAsString(), report: report);
    expect(report.issues, isEmpty);
    expect(made.settings.width, 1080);
    expect(made.settings.height, 1920);
    expect(made.clips.length, 2);
    expect(
      made.clips
          .firstWhere((c) => made.trackById(c.trackId)!.kind == 'video')
          .transform!
          .framing,
      'fill',
    );
    expect(made.media.single.id, asset.id);

    provider.dispose();
    await server.close(force: true);
    temp.deleteSync(recursive: true);
    media.deleteSync(recursive: true);
  }
}
