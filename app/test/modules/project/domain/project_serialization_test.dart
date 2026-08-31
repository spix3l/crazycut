import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/project/domain/clip_transform.dart';
import 'package:crazycut_app/modules/project/domain/param_value.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/project/domain/text_content.dart';
import 'package:crazycut_app/modules/project/domain/transition.dart';
import 'package:crazycut_app/core/math/rational.dart';

void main() {
  group('ParamValue evaluation (engine graph/keyframes.cpp contract)', () {
    ParamValue keys(List<(String, double, String)> kfs) => ParamValue(
          static: 0.0,
          keyframes: [
            for (final (t, v, interp) in kfs)
              {'t': t, 'v': v, 'interp': interp},
          ],
        );

    test('linear interpolation is the raw fraction', () {
      final pv = keys([('0/1', 0.0, 'linear'), ('1/1', 10.0, 'linear')]);
      expect(pv.evaluate(Rt.zero()), 0.0);
      expect(pv.evaluate(Rt.parse('1/4')), 2.5);
      expect(pv.evaluate(Rt.parse('1/2')), 5.0);
      expect(pv.evaluate(Rt.parse('3/4')), 7.5);
    });

    test('easeIn is p*p by the LEFT key', () {
      final pv = keys([('0/1', 1.0, 'easeIn'), ('1/1', 5.0, 'linear')]);
      // p = 0.5 → eased = 0.25 → 1 + (5-1)*0.25 = 2.0
      expect(pv.evaluate(Rt.parse('1/2')), 2.0);
    });

    test('easeOut is 1-(1-p)^2 by the LEFT key', () {
      final pv = keys([('0/1', 1.0, 'easeOut'), ('1/1', 5.0, 'linear')]);
      // p = 0.5 → eased = 0.75 → 1 + 4*0.75 = 4.0
      expect(pv.evaluate(Rt.parse('1/2')), 4.0);
    });

    test('easeInOut is p*p*(3-2p) by the LEFT key', () {
      final pv = keys([('0/1', 1.0, 'easeInOut'), ('1/1', 5.0, 'linear')]);
      // p = 0.5 → eased = 0.5 → 3.0; p = 0.25 → 0.15625 → 1.625
      expect(pv.evaluate(Rt.parse('1/2')), 3.0);
      expect(pv.evaluate(Rt.parse('1/4')), 1.625);
    });

    test('hold steps to the left value inside the segment', () {
      final pv = keys([
        ('0/1', 1.0, 'hold'),
        ('1/2', 2.0, 'hold'),
        ('1/1', 3.0, 'linear'),
      ]);
      expect(pv.evaluate(Rt.parse('1/4')), 1.0); // left key of [0, .5]
      expect(pv.evaluate(Rt.parse('999/2000')), 1.0); // just under .5
      expect(pv.evaluate(Rt.parse('3/4')), 2.0); // hold again in [.5, 1]
      expect(pv.evaluate(Rt.parse('1/1')), 3.0); // last key itself
    });

    test('times outside the span clamp to first/last values', () {
      final pv = keys([('1/4', 7.5, 'easeIn'), ('3/4', 9.5, 'easeOut')]);
      expect(pv.evaluate(Rt.parse('-3/1')), 7.5);
      expect(pv.evaluate(Rt.zero()), 7.5);
      expect(pv.evaluate(Rt.parse('1/1')), 9.5);
      expect(pv.evaluate(Rt.parse('40/1')), 9.5);
    });

    test('point maps lerp per numeric key recursively', () {
      final pv = ParamValue(
        keyframes: [
          {
            't': '0/1',
            'v': {'x': 0.0, 'y': 10.0},
            'interp': 'linear',
          },
          {
            't': '1/1',
            'v': {'x': 100.0, 'y': 20.0},
            'interp': 'linear',
          },
        ],
      );
      final mid = pv.evaluate(Rt.parse('1/2')) as Map;
      expect(mid['x'], 50.0);
      expect(mid['y'], 15.0);
    });

    test('non-numeric payloads hold left until the right key wins at p>=1', () {
      final pv = ParamValue(
        keyframes: [
          {'t': '0/1', 'v': '#FF0000', 'interp': 'linear'},
          {'t': '1/1', 'v': '#00FF00', 'interp': 'linear'},
        ],
      );
      expect(pv.evaluate(Rt.parse('1/2')), '#FF0000');
      expect(pv.evaluate(Rt.parse('1/1')), '#00FF00'); // clamped right
    });

    test('unsorted keys evaluate identically after sorting', () {
      final a = keys([('0/1', 0.0, 'linear'), ('1/1', 10.0, 'linear')]);
      final b = keys([('1/1', 10.0, 'linear'), ('0/1', 0.0, 'linear')]);
      b.sortKeys();
      expect(b.evaluate(Rt.parse('1/2')), a.evaluate(Rt.parse('1/2')));
      expect(a.animated, isTrue);
    });

    test('static values pass through and numOr falls back sanely', () {
      expect(ParamValue.staticNum(42).value, 42.0);
      expect(ParamValue.staticNum(42).numOr(-1), 42.0);
      expect(ParamValue.point(3, 4).value, {'x': 3.0, 'y': 4.0});
      expect(ParamValue.point(3, 4).animated, isFalse);
      expect(ParamValue.from({'static': 'text'}).numOr(5), 5);
      expect(
        ParamValue.fromJson(null).value,
        0.0,
        reason: 'null payload falls back to zero static',
      );
    });
  });

  group('ClipTransform JSON round trip (FX-9)', () {
    test('defaults are engine defaults and toJson writes all keys', () {
      final json = ClipTransform().toJson();
      expect(json['x'], {'static': 0.0});
      expect(json['y'], {'static': 0.0});
      expect(json['scale'], {'static': 100.0});
      expect(json['rotation'], {'static': 0.0});
      expect(json['anchor'], {
        'static': {'x': 0.0, 'y': 0.0},
      });
      expect(json['opacity'], {'static': 100.0});
      expect(json['flipH'], false);
      expect(json['flipV'], false);
      expect(json['framing'], 'fit');
      expect(ClipTransform.fromJson(json).toJson(), json);
    });

    test('missing keys fall back to defaults; animated params round-trip', () {
      const source = {
        'scale': {
          'keyframes': [
            {'t': '0/1', 'v': 50.0, 'interp': 'easeOut'},
            {'t': '1/2', 'v': 120.0},
          ],
        },
        'x': {'static': -20.0},
        'flipH': true,
        'framing': 'fill',
      };
      final t = ClipTransform.fromJson(source);
      expect(t.flipH, true);
      expect(t.framing, 'fill');
      expect(t.x.value, -20.0);
      expect(t.scale.animated, isTrue);
      // p = 0.5 within [0, .5] eased by easeOut → 0.75 → 50 + 70*0.75.
      expect(t.scale.evaluate(Rt.parse('1/4')), 102.5);
      expect(t.rotation.numOr(0), 0);
      expect(t.opacity.numOr(0), 100);
      expect(t.anchor.toJson()['static'], {'x': 0.0, 'y': 0.0});

      final round = ClipTransform.fromJson(t.toJson());
      expect(round.scale.evaluate(Rt.parse('1/4')), 102.5);
      expect(round.x.value, -20.0);
      expect(round.flipV, false);

      // copy() equals content-wise.
      expect(t.copy().toJson(), t.toJson());

      // Malformed param payload quarantines into defaults instead of throwing.
      final bad = ClipTransform.fromJson({'y': 'not-a-param'});
      expect(bad.y.numOr(-1), 0.0);
    });
  });

  group('TextContent JSON round trip (TXT-2/3)', () {
    test('nested groups are written and read back', () {
      final text = TextContent(
        content: 'Hello\nWorld',
        fontFamily: 'Inter',
        fontSize: 48,
        fontWeight: 'w700',
        color: '#FFCC00',
        letterSpacing: 1.5,
        lineHeight: 1.4,
        align: 'left',
        strokeWidth: 2,
        strokeColor: '#111111',
        shadowBlur: 8,
        shadowOffsetX: 3,
        shadowOffsetY: -3,
        shadowColor: '#222222',
        shadowOpacity: 0.5,
        backgroundColor: '#00000080',
        backgroundPadding: 12,
        backgroundRadius: 6,
        animation: 'fade-in',
      );
      final json = text.toJson();
      expect(json['stroke'], {'width': 2.0, 'color': '#111111'});
      expect(json['shadow'], {
        'blur': 8.0,
        'offsetX': 3.0,
        'offsetY': -3.0,
        'color': '#222222',
        'opacity': 0.5,
      });
      expect(json['background'], {
        'color': '#00000080',
        'padding': 12.0,
        'radius': 6.0,
      });
      expect(json['animation'], 'fade-in');

      final round = TextContent.fromJson(json);
      expect(round.content, 'Hello\nWorld');
      expect(round.fontWeight, 'w700');
      expect(round.align, 'left');
      expect(round.shadowOffsetY, -3.0);
      expect(round.backgroundRadius, 6.0);
      expect(round.animation, 'fade-in');
      expect(round.copy().toJson(), json);
    });

    test('missing keys and flat legacy fields fall back with defaults', () {
      final minimal = TextContent.fromJson({});
      expect(minimal.content, '');
      expect(minimal.fontFamily, 'default');
      expect(minimal.fontSize, 64);
      expect(minimal.fontWeight, 'w600');
      expect(minimal.color, '#FFFFFF');
      expect(minimal.lineHeight, 1.2);
      expect(minimal.align, 'center');
      expect(minimal.backgroundColor, '#00000000');

      final flat = TextContent.fromJson({
        'strokeWidth': 4,
        'strokeColor': '#ABCDEF',
        'shadowOpacity': 1,
        'backgroundPadding': 8,
      });
      expect(flat.strokeWidth, 4.0);
      expect(flat.strokeColor, '#ABCDEF');
      expect(flat.shadowOpacity, 1.0);
      expect(flat.backgroundPadding, 8.0);

      expect(TextContent.fromJson({'fontWeight': 'w900'}).fontWeight, 'w600',
          reason: 'weights outside w400..w800 snap back to the default');
      expect(TextContent.fromJson({'fontWeight': 'w800'}).fontWeight, 'w800');
      expect(TextContent.fromJson({'align': 'right'}).align, 'right');
    });
  });

  group('Typed transitions on ProjectDoc', () {
    ProjectDoc twoClips() {
      final doc = ProjectDoc.empty('T');
      doc.media.add(MediaAsset(
        id: 'm1',
        name: 'a.mov',
        path: '/tmp/a.mov',
        type: 'video',
        duration: Rt.fromSeconds(30),
        hasAudio: false,
      ));
      final track = doc.videoTrack()!;
      doc.clips.add(Clip(
        id: 'a',
        trackId: track.id,
        mediaId: 'm1',
        label: 'a',
        start: Rt.zero(),
        duration: Rt.fromSeconds(5),
        sourceIn: Rt.zero(),
      ));
      doc.clips.add(Clip(
        id: 'b',
        trackId: track.id,
        mediaId: 'm1',
        label: 'b',
        start: Rt.fromSeconds(4),
        duration: Rt.fromSeconds(5),
        sourceIn: Rt.fromSeconds(5),
      ));
      return doc;
    }

    test('easing catalog defaults apply only when JSON omits easing', () {
      expect(Transition.defaultEasingFor('slideLeft'), 'easeOut');
      expect(Transition.defaultEasingFor('pushUp'), 'linear');
      expect(Transition.defaultEasingFor('crossDissolve'), 'easeInOut');
      expect(
        Transition.fromJson({'id': 't1', 'type': 'slideRight'}).easing,
        'easeOut',
      );
      expect(
        Transition.fromJson({
          'id': 't2',
          'type': 'slideRight',
          'easing': 'linear',
        }).easing,
        'linear',
      );
      expect(
        Transition.fromJson({'id': 't3'}).toJson()['duration'],
        '1/2',
        reason: 'default duration is half a second',
      );
    });

    test('round trips through JSON preserving every field', () {
      final tr = Transition(
        id: 't1',
        aClipId: 'a',
        bClipId: 'b',
        type: 'pushLeft',
        duration: Rt.parse('3/2'),
        alignment: 'end',
        easing: 'linear',
        aExtend: Rt.parse('1/1'),
        bExtend: Rt.parse('1/2'),
        params: {'softness': 0.4},
      );
      final round = Transition.fromJson(tr.toJson());
      expect(round.toJson(), tr.toJson());
      expect(round.duration, Rt.parse('3/2'));
      expect(round.alignment, 'end');
      expect(round.aExtend, Rt.parse('1/1'));
      expect(round.params, {'softness': 0.4});

      final minimal = Transition.fromJson({
        'id': 't2',
        'aClipId': 'a',
        'bClipId': 'b',
        'duration': '1/1',
      });
      expect(minimal.type, 'crossDissolve');
      expect(minimal.alignment, 'center');
      expect(minimal.easing, 'easeInOut');
      expect(minimal.aExtend, Rt.zero());
      expect(minimal.bExtend, Rt.zero());
      expect(minimal.params, isEmpty);
    });

    test('loader keeps a consistent transition and drops broken ones', () {
      // Consistent: overlap [4,5] = 1s on the same track.
      final doc = twoClips();
      doc.transitions.add(Transition(
        id: 'ok',
        aClipId: 'a',
        bClipId: 'b',
        duration: Rt.fromSeconds(1),
      ));

      final json = jsonDecode(doc.encode()) as Map<String, dynamic>;
      (json['tracks'] as List<dynamic>)
          .add(Track(id: 't-other', kind: 'video', name: 'V9', index: 9).toJson());
      (json['clips'] as List<dynamic>).add({
        'id': 'c',
        'trackId': 't-other',
        'mediaId': 'm1',
        'label': 'c',
        'start': '4/1',
        'duration': '5/1',
        'sourceIn': '0/1',
      });
      void addTransition(Map<String, dynamic> t) =>
          (json['transitions'] as List<dynamic>).add(t);
      // Unknown clip reference.
      addTransition({
        'id': 'unknown-clip',
        'aClipId': 'missing-a',
        'bClipId': 'b',
        'type': 'crossDissolve',
        'duration': '1/1',
        'alignment': 'center',
      });
      // Clips on different tracks.
      addTransition({
        'id': 'cross-track',
        'aClipId': 'a',
        'bClipId': 'c',
        'type': 'dipToBlack',
        'duration': '1/1',
        'alignment': 'center',
      });
      // Non-positive duration.
      addTransition({
        'id': 'zero-duration',
        'aClipId': 'a',
        'bClipId': 'b',
        'duration': '0/1',
        'alignment': 'center',
      });
      // Duration != computed overlap.
      addTransition({
        'id': 'wrong-span',
        'aClipId': 'a',
        'bClipId': 'b',
        'duration': '1/2',
        'alignment': 'center',
      });
      // Unparseable payload quarantined by the loader.
      addTransition({'id': 'malformed-json', 'duration': 17});

      final report = RepairReport();
      final loaded = ProjectDoc.fromJson(json, report: report);
      expect(loaded.transitions.single.id, 'ok');
      expect(loaded.transitionById('ok'), same(loaded.transitions.single));
      expect(loaded.transitionById('nope'), isNull);
      expect(report.issues, hasLength(5));
      final joined = report.issues.join('\n');
      for (final id in ['unknown-clip', 'cross-track', 'zero-duration',
        'wrong-span']) {
        expect(joined, contains(id), reason: 'report should name $id');
      }
      expect(joined, contains('transition:'),
          reason: 'the malformed entry still quarantines with a report line');

      // Round trip through encode()/decode() preserves the survivor.
      final re = ProjectDoc.decode(loaded.encode());
      expect(re.transitions.single.id, 'ok');
      expect(re.clips.map((c) => c.id), containsAll(['a', 'b']));
    });

    test('duplicate() remaps transition clip ids and issues fresh ids', () {
      final doc = twoClips();
      doc.transitions.add(Transition(
        id: 't-ab',
        aClipId: 'a',
        bClipId: 'b',
        duration: Rt.fromSeconds(1),
      ));

      final copy = doc.duplicate();
      expect(copy.transitions, hasLength(1));
      final t = copy.transitions.single;
      expect(t.id, isNot('t-ab'));
      final oldIds = {'a', 'b'};
      expect(oldIds.contains(t.aClipId), isFalse,
          reason: 'aClipId must map to the fresh clone id');
      expect(oldIds.contains(t.bClipId), isFalse,
          reason: 'bClipId must map to the fresh clone id');
      final copyIds = copy.clips.map((c) => c.id).toSet();
      expect(copyIds.contains(t.aClipId), isTrue);
      expect(copyIds.contains(t.bClipId), isTrue);

      // The remapped pair still overlaps by exactly the transition duration.
      final ca = copy.clipById(t.aClipId)!;
      final cb = copy.clipById(t.bClipId)!;
      final overlapStart = ca.start > cb.start ? ca.start : cb.start;
      final overlapEnd = ca.end < cb.end ? ca.end : cb.end;
      expect(overlapEnd.minus(overlapStart), t.duration);

      // Original untouched.
      expect(doc.transitions.single.id, 't-ab');
      expect(doc.clipById('a'), isNotNull);
    });

    test('forward-safe extras survive on clips carrying transform and text',
        () {
      final doc = twoClips();
      final clip = doc.clips.first;
      clip.transform = ClipTransform(x: ParamValue.staticNum(12));
      clip.text = TextContent(content: 'caption');
      clip.extra['futureField'] = <String, dynamic>{'deep': true};

      final json = jsonDecode(doc.encode()) as Map<String, dynamic>;
      final clipJson =
          (json['clips'] as List<dynamic>).first as Map<String, dynamic>;
      expect(clipJson['transform'], isA<Map<String, dynamic>>());
      expect(clipJson['text'], isA<Map<String, dynamic>>());
      expect(clipJson['blend'], isNull,
          reason: "blend 'normal' must be omitted");
      expect(clipJson['futureField'], {'deep': true});

      final loaded = ProjectDoc.fromJson(json);
      final back = loaded.clips.first;
      expect(back.transform!.x.numOr(-1), 12.0);
      expect(back.text!.content, 'caption');
      expect(back.blend, 'normal');
      expect(back.extra['futureField'], {'deep': true});
    });

    test('blend writes only when non-default; text clips carry empty mediaId',
        () {
      final doc = twoClips();
      doc.clips[0].blend = 'multiply';
      final json = jsonDecode(doc.encode()) as Map<String, dynamic>;
      final clips = json['clips'] as List<dynamic>;
      expect((clips[0] as Map<String, dynamic>)['blend'], 'multiply');
      expect((clips[1] as Map<String, dynamic>)['blend'], isNull);
      final loaded = ProjectDoc.fromJson(json);
      expect(loaded.clips[0].blend, 'multiply');

      final textClip = Clip(
        id: 'txt',
        trackId: doc.videoTrack()!.id,
        mediaId: '',
        label: 'title',
        start: Rt.zero(),
        duration: Rt.fromSeconds(2),
        sourceIn: Rt.zero(),
        text: TextContent(),
      );
      expect(textClip.mediaId, '');
      expect(textClip.transform, isNull);
      expect(textClip.transformOrDefault.framing, 'fit');
      expect(identical(textClip.transformOrDefault, textClip.transform), false,
          reason: 'default getter returns a fresh instance when unset');
      expect(textClip.copy().text!.toJson(), TextContent().toJson());
    });
  });
}
