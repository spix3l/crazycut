import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/project/domain/caption.dart';
import 'package:crazycut_app/modules/editor/application/caption_interchange.dart';
import 'package:crazycut_app/core/math/rational.dart';

String Function() ids() {
  var next = 0;
  return () => 'id-${next++}';
}

CaptionTrack fixture() => CaptionTrack(
  id: 'track',
  name: 'English',
  language: 'en',
  items: [
    CaptionItem(
      id: 'one',
      start: Rt.fromSeconds(1.234),
      duration: Rt.fromSeconds(2.111),
      text: 'First line\nSecond line',
    ),
    CaptionItem(
      id: 'two',
      start: Rt.fromSeconds(65.678),
      duration: Rt.fromSeconds(1.5),
      text: 'Spoken text',
      speaker: 'Alex',
    ),
  ],
);

void expectTimingNear(CaptionTrack actual, CaptionTrack expected) {
  expect(actual.items, hasLength(expected.items.length));
  for (var i = 0; i < expected.items.length; i++) {
    expect(
      (actual.items[i].start.seconds - expected.items[i].start.seconds).abs(),
      lessThanOrEqualTo(0.001),
    );
    expect(
      (actual.items[i].end.seconds - expected.items[i].end.seconds).abs(),
      lessThanOrEqualTo(0.001),
    );
    expect(actual.items[i].text, expected.items[i].text);
  }
}

void main() {
  test('SRT exports and imports multiline cues within one millisecond', () {
    final source = CaptionInterchange.exportSrt(fixture());
    expect(source, contains('00:00:01,234 --> 00:00:03,345'));
    final imported = CaptionInterchange.importSrt(
      '\ufeff${source.replaceAll('\n', '\r\n')}',
      idFactory: ids(),
      options: const CaptionImportOptions(language: 'en'),
    );

    expect(imported.format, CaptionFormat.srt);
    expect(imported.track.language, 'en');
    expect(imported.issues, isEmpty);
    expectTimingNear(imported.track, fixture());
  });

  test('WebVTT round-trip retains voice metadata and cue settings parse', () {
    final source = CaptionInterchange.exportWebVtt(fixture());
    final imported = CaptionInterchange.importWebVtt(
      source.replaceFirst(
        '00:00:01.234 --> 00:00:03.345',
        '00:00:01.234 --> 00:00:03.345 align:center position:50%',
      ),
      idFactory: ids(),
    );

    expect(imported.issues, isEmpty);
    expectTimingNear(imported.track, fixture());
    expect(imported.track.items.last.speaker, 'Alex');
  });

  test('imports WebVTT notes and cue identifiers', () {
    const source = '''WEBVTT - generated locally
Kind: captions
Language: en

NOTE generated locally
this block is ignored

intro-cue
00:01.000 --> 00:03.000
Hello
''';
    final imported = CaptionInterchange.parse(source, idFactory: ids());

    expect(imported.format, CaptionFormat.webVtt);
    expect(imported.track.items.single.text, 'Hello');
    expect(imported.track.items.single.start, Rt.fromSeconds(1));
    expect(imported.issues, isEmpty);
  });

  test('reports bad blocks and repairs invalid duration and overlap', () {
    const source = '''1
00:00:01,000 --> 00:00:03,000
First

2
00:00:02,000 --> 00:00:01,000
Second

3
not a timestamp
Broken

4
00:00:05,000 --> 00:00:06,000
''';
    final imported = CaptionInterchange.importSrt(
      source,
      idFactory: ids(),
      options: const CaptionImportOptions(frameRate: 25),
    );

    expect(imported.track.items, hasLength(2));
    expect(imported.repairCount, 2);
    expect(imported.hasErrors, isTrue);
    expect(imported.track.items[1].start, imported.track.items[0].end);
    expect(
      imported.track.items[1].duration.seconds,
      greaterThanOrEqualTo(0.04),
    );
  });

  test('missing WebVTT header is accepted with a repair report', () {
    const source = '''00:00.000 --> 00:01.000
Hello
''';
    final imported = CaptionInterchange.importWebVtt(source, idFactory: ids());

    expect(imported.track.items.single.text, 'Hello');
    expect(imported.repairCount, 1);
  });
}
