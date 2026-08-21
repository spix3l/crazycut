import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';

void main() {
  test('ids are time-ordered and unique (UUIDv7 shape, §3)', () {
    final ids = List.generate(200, (_) => generateId());
    expect(ids.toSet(), hasLength(200));
    expect(ids.every((id) => id.length == 36), isTrue);
    expect(ids.every((id) => id[14] == '7'), isTrue);
  });

  test('unknown fields survive a load/save round trip (§1 forward-safe)', () {
    final source = ProjectDoc.empty('Round trip');
    final json = jsonDecode(source.encode()) as Map<String, dynamic>;
    json['futureFeature'] = {'enabled': true};
    (json['tracks'] as List<dynamic>).first['pinned'] = true;
    json['clips'] = [
      {
        'id': 'c1',
        'trackId': (json['tracks'] as List<dynamic>).first['id'],
        'mediaId': 'm1',
        'label': 'x',
        'start': '0/1',
        'duration': '5/1',
        'sourceIn': '0/1',
        'colorTag': 'blue',
      },
    ];

    final doc = ProjectDoc.fromJson(json);
    final round = jsonDecode(doc.encode()) as Map<String, dynamic>;

    expect(round['futureFeature'], {'enabled': true});
    expect((round['tracks'] as List<dynamic>).first['pinned'], isTrue);
    expect((round['clips'] as List<dynamic>).first['colorTag'], 'blue');
  });

  test('the loader quarantines broken entities instead of throwing (§10)', () {
    final doc = ProjectDoc.empty('Repair');
    final json = jsonDecode(doc.encode()) as Map<String, dynamic>;
    json['clips'] = [
      {
        'id': 'orphan',
        'trackId': 'missing-track',
        'mediaId': 'm1',
        'label': 'orphan',
        'start': '0/1',
        'duration': '5/1',
        'sourceIn': '0/1',
      },
      {
        'id': 'zero',
        'trackId': (json['tracks'] as List<dynamic>).first['id'],
        'mediaId': 'm1',
        'label': 'zero',
        'start': '0/1',
        'duration': '0/1',
        'sourceIn': '0/1',
      },
    ];

    final report = RepairReport();
    final repaired = ProjectDoc.fromJson(json, report: report);

    expect(repaired.clips, isEmpty);
    expect(report.issues, hasLength(2));
  });

  test('a newer schema major is refused with a readable message (§9)', () {
    final doc = ProjectDoc.empty('Future');
    final json = jsonDecode(doc.encode()) as Map<String, dynamic>;
    json['schema'] = 'crazycut/project@2';

    expect(
      () => ProjectDoc.decode(jsonEncode(json)),
      throwsA(isA<FormatException>()),
    );
  });

  test('duplicate makes an independent copy with new ids (PRJ criterion 3)', () {
    final doc = ProjectDoc.empty('Original');
    final track = doc.videoTrack()!;
    doc.media.add(MediaAsset(
      id: 'm1',
      name: 'a.mov',
      path: '/tmp/a.mov',
      type: 'video',
      duration: Rt.fromSeconds(10),
      hasAudio: false,
    ));
    doc.clips.add(Clip(
      id: 'c1',
      trackId: track.id,
      mediaId: 'm1',
      label: 'a.mov',
      start: Rt.zero(),
      duration: Rt.fromSeconds(5),
      sourceIn: Rt.zero(),
      linkedGroup: 'g1',
    ));

    final copy = doc.duplicate();

    expect(copy.id, isNot(doc.id));
    expect(copy.clips.single.id, isNot('c1'));
    expect(copy.tracks.first.id, isNot(track.id));
    expect(copy.clips.single.trackId, copy.tracks.first.id);
    expect(copy.clips.single.mediaId, copy.media.single.id);
    expect(copy.clips.single.linkedGroup, isNot('g1'));

    // Editing the copy leaves the original alone.
    copy.clips.single.start = Rt.fromSeconds(9);
    expect(doc.clips.single.start, Rt.zero());
  });

  test('proxy rules follow architecture §5', () {
    MediaAsset asset({int? height, String? codec, bool vfr = false, int? bitrate}) =>
        MediaAsset(
          id: 'a',
          name: 'a.mov',
          path: '/tmp/a.mov',
          type: 'video',
          duration: Rt.fromSeconds(5),
          hasAudio: false,
          height: height,
          codec: codec,
          vfr: vfr,
          bitrate: bitrate,
        );

    expect(asset(height: 1080, codec: 'h264').wantsProxy, isFalse);
    expect(asset(height: 2160, codec: 'h264').wantsProxy, isTrue);
    expect(asset(height: 1080, codec: 'hevc').wantsProxy, isTrue);
    expect(asset(height: 1080, codec: 'av1').wantsProxy, isTrue);
    expect(asset(height: 1080, codec: 'h264', vfr: true).wantsProxy, isTrue);
    expect(asset(height: 1080, codec: 'h264', bitrate: 80000000).wantsProxy, isTrue);
  });

  test('sequence frame duration is exact for NTSC rates (§2)', () {
    final doc = ProjectDoc.empty('NTSC', fps: 29.97);
    expect(doc.settings.fps, '29970/1001');
    expect(doc.frameDuration, Rt(1001, 29970));
    // Thirty frames add up without drift.
    var t = Rt.zero();
    for (var i = 0; i < 30; i++) {
      t = t.plus(doc.frameDuration);
    }
    expect(t, Rt(30030, 29970));
  });
}
