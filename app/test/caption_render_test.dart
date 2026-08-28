import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/caption.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/caption_rasterizer.dart';
import 'package:crazycut_app/state/export_service.dart';

CaptionTrack _track() => CaptionTrack(
  id: 'captions',
  name: 'English',
  language: 'en',
  style: CaptionStyle(
    fontSize: 48,
    maxWidth: 0.6,
    highlightWords: true,
    textColor: '#FFFFFFFF',
    highlightColor: '#FFD400FF',
  ),
  items: [
    CaptionItem(
      id: 'cue',
      start: Rt.fromSeconds(1),
      duration: Rt.fromSeconds(2),
      text: 'Hello, 世界!\nSecond line',
      words: [
        CaptionWord(
          start: Rt.fromSeconds(1),
          end: Rt.fromSeconds(1.5),
          text: 'Hello',
        ),
        CaptionWord(
          start: Rt.fromSeconds(1.5),
          end: Rt.fromSeconds(2),
          text: '世界',
        ),
      ],
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('caption keys and active words use half-open exact time ranges', () {
    final track = _track();
    final item = track.items.single;
    expect(activeCaptionWord(track, item, Rt.fromSeconds(0.99)), isNull);
    expect(activeCaptionWord(track, item, Rt.fromSeconds(1)), 0);
    expect(activeCaptionWord(track, item, Rt.fromSeconds(1.5)), 1);
    expect(activeCaptionWord(track, item, Rt.fromSeconds(2)), isNull);
    expect(captionTextureKey(track, item), 'caption:captions:cue');
    expect(
      captionTextureKey(track, item, highlightedWord: 1),
      'caption:captions:cue:h:1',
    );
  });

  test('range sidecars clip and rebase cues without mutating the project', () {
    final source = _track();
    final result = captionSidecarTrack(
      source,
      startSeconds: 1.25,
      endSeconds: 1.75,
    );
    expect(result.items.single.start, Rt.zero());
    expect(result.items.single.duration, Rt.fromSeconds(0.5));
    expect(result.items.single.words.first.start, Rt.zero());
    expect(result.items.single.words.last.end, Rt.fromSeconds(0.5));
    expect(source.items.single.start, Rt.fromSeconds(1));
  });

  test('Unicode multiline caption and highlight variants rasterize', () async {
    final track = _track();
    final item = track.items.single;
    final plain = await CaptionRasterizer.instance.render(
      track,
      item,
      canvasWidth: 360,
      sequenceHeight: 640,
    );
    final highlighted = await CaptionRasterizer.instance.render(
      track,
      item,
      canvasWidth: 360,
      sequenceHeight: 640,
      highlightedWord: 1,
    );
    expect(plain, isNotNull);
    expect(highlighted, isNotNull);
    expect(plain!.width, lessThanOrEqualTo(360));
    expect(plain.height, greaterThan(20));
    expect(highlighted!.bytes, isNot(equals(plain.bytes)));
  });
}
