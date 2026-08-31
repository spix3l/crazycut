import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/project/domain/caption.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/application/commands.dart';

Rt seconds(double value) => Rt.fromSeconds(value);

CaptionTrack captions() => CaptionTrack(
  id: 'captions-1',
  name: 'English',
  language: 'en-US',
  style: CaptionStyle(preset: 'creator', highlightWords: true),
  items: [
    CaptionItem(
      id: 'cue-1',
      start: seconds(1),
      duration: seconds(2),
      text: 'Hello world',
      speaker: 'Host',
      words: [
        CaptionWord(
          id: 'word-1',
          start: seconds(1),
          end: seconds(1.5),
          text: 'Hello',
          confidence: 0.97,
        ),
        CaptionWord(
          id: 'word-2',
          start: seconds(1.5),
          end: seconds(2),
          text: 'world',
        ),
      ],
    ),
  ],
);

void main() {
  test('old projects without captions round-trip without a new payload', () {
    final original =
        ProjectDoc.empty('Legacy').toJson()..remove('captionTracks');

    final loaded = ProjectDoc.fromJson(original);
    final saved = loaded.toJson();

    expect(loaded.captionTracks, isEmpty);
    expect(saved, isNot(contains('captionTracks')));
  });

  test('caption hierarchy and unknown fields round-trip exactly', () {
    final doc = ProjectDoc.empty('Caption round trip');
    final track = captions();
    track.extra['futureTrack'] = true;
    track.style.extra['futureStyle'] = {'mode': 'outline'};
    track.items.single.extra['futureCue'] = 7;
    track.items.single.words.first.extra['futureWord'] = 'kept';
    doc.captionTracks.add(track);

    final loaded = ProjectDoc.decode(doc.encode(touchModified: false));
    final json = loaded.captionTracks.single.toJson();

    expect(json, track.toJson());
    expect(loaded.sequenceDuration, seconds(3));
  });

  test('caption words do not require their own identity', () {
    final word = CaptionWord(
      start: Rt.zero(),
      end: seconds(0.5),
      text: 'Hello',
    );

    expect(word.toJson(), isNot(contains('id')));
    expect(CaptionWord.fromJson(word.toJson()).text, 'Hello');
  });

  test('caption repair enforces ordering, one frame and no overlaps', () {
    final source = ProjectDoc.empty('Repair', fps: 25).toJson();
    source['captionTracks'] = [
      {
        'id': 't1',
        'name': 'English',
        'language': 'en',
        'style': <String, dynamic>{},
        'items': [
          {'id': 'later', 'start': '1/1', 'duration': '1/100', 'text': 'later'},
          {
            'id': 'negative',
            'start': '-1/1',
            'duration': '2/1',
            'text': 'first',
            'words': [
              {
                'id': 'w1',
                'start': '-1/1',
                'end': '0/1',
                'text': 'first',
                'confidence': 2,
              },
            ],
          },
        ],
      },
    ];
    final report = RepairReport();

    final doc = ProjectDoc.fromJson(source, report: report);
    final items = doc.captionTracks.single.items;

    expect(items.map((item) => item.id), ['negative', 'later']);
    expect(items.first.start, Rt.zero());
    expect(items.first.end, seconds(2));
    expect(items.last.start, seconds(2));
    expect(items.last.duration, Rt(1, 25));
    expect(items.first.words.single.start, Rt.zero());
    expect(items.first.words.single.end, seconds(1));
    expect(items.first.words.single.confidence, 1.0);
    expect(report.issues, isNotEmpty);
  });

  test('repair drops duplicate ids and invalid word spans', () {
    final doc = ProjectDoc.empty('Duplicates');
    final track = captions();
    track.items.add(track.items.single.copy());
    track.items.first.words.add(track.items.first.words.first.copy());
    track.items.first.words.add(
      CaptionWord(
        id: 'bad',
        start: seconds(4),
        end: seconds(5),
        text: 'outside',
      ),
    );
    doc.captionTracks
      ..add(track)
      ..add(track.copy());
    final report = RepairReport();

    final repaired = ProjectDoc.fromJson(doc.toJson(), report: report);

    expect(repaired.captionTracks, hasLength(1));
    expect(repaired.captionTracks.single.items, hasLength(1));
    expect(repaired.captionTracks.single.items.single.words, hasLength(2));
    expect(
      repaired.captionTracks.single.items.single.words.any(
        (word) => word.id == 'bad',
      ),
      isFalse,
    );
    expect(
      report.issues.where((issue) => issue.contains('duplicate')),
      hasLength(3),
    );
  });

  test('malformed caption children are quarantined independently', () {
    final source = ProjectDoc.empty('Quarantine').toJson();
    source['captionTracks'] = [
      {
        'id': 't1',
        'name': 'English',
        'language': 'en',
        'items': [
          {
            'id': 'good',
            'start': '0/1',
            'duration': '1/1',
            'text': 'kept',
            'words': [
              {'id': 'good-word', 'start': '0/1', 'end': '1/2', 'text': 'kept'},
              {'id': 'bad-word', 'start': 'not-time'},
            ],
          },
          {'id': 'bad-item', 'start': 'not-time'},
        ],
      },
    ];
    final report = RepairReport();

    final doc = ProjectDoc.fromJson(source, report: report);

    expect(doc.captionTracks, hasLength(1));
    expect(doc.captionTracks.single.items.single.id, 'good');
    expect(doc.captionTracks.single.items.single.words.single.id, 'good-word');
    expect(report.issues, hasLength(2));
  });

  test('project duplicate gives every caption entity a fresh identity', () {
    final doc = ProjectDoc.empty('Original')..captionTracks.add(captions());

    final copy = doc.duplicate();
    final originalTrack = doc.captionTracks.single;
    final copiedTrack = copy.captionTracks.single;

    expect(copiedTrack.id, isNot(originalTrack.id));
    expect(copiedTrack.items.single.id, isNot(originalTrack.items.single.id));
    expect(
      copiedTrack.items.single.words
          .map((word) => word.id)
          .toSet()
          .intersection(
            originalTrack.items.single.words.map((word) => word.id).toSet(),
          ),
      isEmpty,
    );
    copiedTrack.items.single.text = 'Independent';
    expect(originalTrack.items.single.text, 'Hello world');
  });

  test('caption text timing and style edit undo and redo as one command', () {
    final doc = ProjectDoc.empty('Commands')..captionTracks.add(captions());
    final tx = EditTransaction(doc, 'Edit captions')
      ..captionTrack('captions-1');
    final track = doc.captionTracks.single;
    track.style.fontSize = 64;
    track.items.single
      ..text = 'Edited'
      ..start = seconds(2);
    final edit = tx.build();

    expect(edit, isNotNull);
    final stack = CommandStack()..push(edit!);
    stack.undo(doc);
    expect(doc.captionTracks.single.style.fontSize, 48);
    expect(doc.captionTracks.single.items.single.text, 'Hello world');
    expect(doc.captionTracks.single.items.single.start, seconds(1));

    stack.redo(doc);
    expect(doc.captionTracks.single.style.fontSize, 64);
    expect(doc.captionTracks.single.items.single.text, 'Edited');
    expect(doc.captionTracks.single.items.single.start, seconds(2));
  });

  test('caption track creation and deletion are undoable', () {
    final doc = ProjectDoc.empty('Commands');
    final create = EditTransaction(doc, 'Add caption track')
      ..captionTrack('captions-1');
    doc.captionTracks.add(captions());
    final stack = CommandStack()..push(create.build()!);

    stack.undo(doc);
    expect(doc.captionTracks, isEmpty);
    stack.redo(doc);
    expect(doc.captionTracks.single.id, 'captions-1');

    final remove = EditTransaction(doc, 'Delete caption track')
      ..captionTrack('captions-1');
    doc.captionTracks.clear();
    stack.push(remove.build()!);
    stack.undo(doc);
    expect(doc.captionTracks.single.items.single.text, 'Hello world');
  });

  test('caption JSON remains autosave/recovery compatible', () {
    final doc = ProjectDoc.empty('Autosave')..captionTracks.add(captions());
    final autosave = jsonEncode(doc.toJson());

    final recovered = ProjectDoc.decode(autosave);

    expect(recovered.captionTracks.single.toJson(), captions().toJson());
  });
}
