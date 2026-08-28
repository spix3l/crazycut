import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/caption_segmentation.dart';
import 'package:crazycut_app/data/transcript.dart';

String Function() ids() {
  var next = 0;
  return () => 'id-${next++}';
}

void main() {
  test('segments transcript on punctuation, silence and length', () {
    const transcript = Transcript(
      language: 'en',
      durationSeconds: 12,
      segments: [
        TranscriptSegment(
          start: 0,
          end: 2,
          text: 'This is the first sentence.',
        ),
        TranscriptSegment(start: 2.1, end: 4, text: 'A short follow up'),
        TranscriptSegment(start: 5, end: 7, text: 'After a useful pause'),
      ],
    );

    final result = const CaptionSegmenter().convert(
      transcript,
      idFactory: ids(),
      trackId: 'track',
      options: const CaptionSegmentationOptions(maxCharactersPerLine: 18),
    );

    expect(result.track.id, 'track');
    expect(result.track.language, 'en');
    expect(result.track.items, hasLength(greaterThanOrEqualTo(3)));
    expect(result.track.items.first.text, contains('first'));
    expect(result.track.items.expand((cue) => cue.words), isNotEmpty);
    for (final cue in result.track.items) {
      expect(cue.duration.seconds, greaterThanOrEqualTo(0.8));
      expect(cue.text.split('\n'), hasLength(lessThanOrEqualTo(2)));
      for (final word in cue.words) {
        expect(word.start, greaterThanOrEqualTo(cue.start));
        expect(word.end, lessThanOrEqualTo(cue.end));
      }
    }
  });

  test('repairs malformed segments and applies a sequence offset', () {
    const transcript = Transcript(
      language: '',
      durationSeconds: 4,
      segments: [
        TranscriptSegment(start: -1, end: 1, text: 'negative start'),
        TranscriptSegment(start: 0.5, end: 0.25, text: 'bad duration'),
      ],
    );

    final result = const CaptionSegmenter().convert(
      transcript,
      idFactory: ids(),
      options: const CaptionSegmentationOptions(
        sequenceOffset: Duration(seconds: 3),
      ),
    );

    expect(result.track.language, 'und');
    expect(result.track.items.first.start.seconds, greaterThanOrEqualTo(3));
    expect(result.issues.where((issue) => issue.repaired), isNotEmpty);
  });

  test('a ten-minute transcript converts locally into ordered cues', () {
    final transcript = Transcript(
      language: 'en',
      durationSeconds: 600,
      segments: [
        for (var second = 0; second < 600; second += 3)
          TranscriptSegment(
            start: second.toDouble(),
            end: second + 2.4,
            text: 'A concise editable caption number $second.',
          ),
      ],
    );
    final result = const CaptionSegmenter().convert(
      transcript,
      idFactory: ids(),
    );

    expect(result.track.items, hasLength(200));
    for (var i = 1; i < result.track.items.length; i++) {
      expect(
        result.track.items[i].start,
        greaterThanOrEqualTo(result.track.items[i - 1].end),
      );
    }
  });
}
