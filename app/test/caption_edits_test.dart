import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/caption.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/caption_edits.dart';
import 'package:crazycut_app/state/timeline_edits.dart';

Rt seconds(num value) => Rt.fromSeconds(value.toDouble());

class CaptionHarness extends ChangeNotifier with TimelineEdits, CaptionEdits {
  CaptionHarness(this.doc);

  @override
  final ProjectDoc doc;

  @override
  Rt playhead = Rt.zero();

  @override
  double get fps => doc.settings.fpsValue;

  @override
  void markDirty() {}

  @override
  void seekToCaption(CaptionItem item) => playhead = item.start;
}

CaptionHarness harness() {
  final doc = ProjectDoc.empty('Caption edits');
  doc.captionTracks.add(
    CaptionTrack(
      id: 'track',
      name: 'English',
      language: 'en',
      items: [
        CaptionItem(
          id: 'one',
          start: seconds(1),
          duration: seconds(2),
          text: 'Hello there',
        ),
        CaptionItem(
          id: 'two',
          start: seconds(4),
          duration: seconds(2),
          text: 'General Kenobi',
        ),
      ],
    ),
  );
  return CaptionHarness(doc)..selectCaption('track', 'one');
}

void main() {
  test('text correction and speaker are undoable as separate commits', () {
    final c = harness();
    c.updateCaptionText('track', 'one', 'Corrected');
    c.updateCaptionSpeaker('track', 'one', 'Narrator');

    expect(c.selectedCaptionItem!.text, 'Corrected');
    expect(c.selectedCaptionItem!.speaker, 'Narrator');
    c.undo();
    expect(c.selectedCaptionItem!.text, 'Corrected');
    expect(c.selectedCaptionItem!.speaker, isNull);
    c.undo();
    expect(c.selectedCaptionItem!.text, 'Hello there');
  });

  test('split and merge preserve cue extent and undo in one step', () {
    final c = harness();
    expect(c.splitCaption('track', 'one', seconds(2)), isTrue);

    final track = c.doc.captionTracks.single;
    expect(track.items, hasLength(3));
    expect(track.items[0].text, 'Hello');
    expect(track.items[1].text, 'there');
    expect(track.items[1].end, seconds(3));

    expect(c.mergeCaptionWithNext('track', track.items[0].id), isTrue);
    expect(track.items, hasLength(2));
    expect(track.items.first.text, 'Hello there');
    expect(track.items.first.end, seconds(3));
    c.undo();
    expect(c.doc.captionTracks.single.items, hasLength(3));
  });

  test('nudge and retime cannot overlap neighboring cues', () {
    final c = harness();
    expect(c.nudgeCaption('track', 'one', 60), isTrue);
    final one = c.doc.captionTracks.single.items.first;
    expect(one.end <= seconds(4), isTrue);

    expect(
      c.retimeCaption(
        'track',
        'one',
        start: seconds(3.99),
        duration: seconds(5),
      ),
      isTrue,
    );
    expect(one.duration >= c.frameDuration, isTrue);
    expect(one.end <= seconds(4), isTrue);
  });

  test('track-wide style edit is undoable', () {
    final c = harness();
    c.updateCaptionStyle(
      'track',
      preset: 'creator',
      fontSize: 72,
      highlightWords: true,
    );
    expect(c.doc.captionTracks.single.style.fontSize, 72);
    expect(c.doc.captionTracks.single.style.highlightWords, isTrue);
    c.undo();
    expect(c.doc.captionTracks.single.style.fontSize, 48);
    expect(c.doc.captionTracks.single.style.highlightWords, isFalse);
  });

  test('lane-style gesture coalesces repeated retimes into one undo', () {
    final c = harness();
    c.beginGesture('Retime caption');
    c.retimeCaption('track', 'one', start: seconds(1.5));
    c.retimeCaption('track', 'one', start: seconds(1.75));
    c.endGesture();
    expect(
      c.doc.captionTracks.single.items.first.start,
      c.quantiseToFrame(seconds(1.75)),
    );

    c.undo();
    expect(c.doc.captionTracks.single.items.first.start, seconds(1));
    expect(c.canUndo, isFalse);
  });
}
