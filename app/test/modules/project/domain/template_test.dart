import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/project/infrastructure/repository.dart';
import 'package:crazycut_app/modules/project/domain/template.dart';
import 'package:crazycut_app/modules/editor/infrastructure/template_library.dart';
import 'package:crazycut_app/modules/project/domain/text_content.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/application/template_edits.dart';
import 'package:crazycut_app/modules/editor/application/timeline_edits.dart';

/// Minimal host for the mixins — no engine, no autosave (see
/// `timeline_edits_test.dart`).
class Edits extends ChangeNotifier with TimelineEdits, TemplateEdits {
  Edits(this.doc);

  @override
  final ProjectDoc doc;

  @override
  Rt playhead = Rt.zero();

  @override
  double get fps => doc.settings.fpsValue;

  @override
  void markDirty() {}
}

Rt s(double seconds) => Rt.fromSeconds(seconds);

Edits harness({double assetSeconds = 20}) {
  final doc = ProjectDoc.empty('Test', width: 1920, height: 1080, fps: 30);
  doc.media.add(
    MediaAsset(
      id: 'asset-1',
      name: 'clip.mov',
      path: '/tmp/clip.mov',
      type: 'video',
      duration: s(assetSeconds),
      hasAudio: false,
      hash: 'sha256:aaaa',
    ),
  );
  return Edits(doc);
}

Clip addClip(
  Edits e, {
  required String id,
  required double start,
  required double duration,
  double sourceIn = 0,
  String? trackId,
  String mediaId = 'asset-1',
  String? text,
}) {
  final clip = Clip(
    id: id,
    trackId: trackId ?? e.doc.videoTrack()!.id,
    mediaId: mediaId,
    label: id,
    start: s(start),
    duration: s(duration),
    sourceIn: s(sourceIn),
    text: text == null ? null : TextContent(content: text),
  );
  e.doc.clips.add(clip);
  return clip;
}

/// Source project: A|B joined by a dissolve on V1, a title on V2.
(Edits, ClipTemplate) authoredTemplate({bool withText = true}) {
  final e = harness();
  addClip(e, id: 'a', start: 0, duration: 5, sourceIn: 2);
  addClip(e, id: 'b', start: 5, duration: 5, sourceIn: 8);
  final trId = e.addTransition('a', 'b', duration: s(0.5));
  expect(trId, isNotNull);

  final ids = <String>['a', 'b'];
  if (withText) {
    final v2 = e.addTrack('video');
    addClip(
      e,
      id: 'title',
      start: 1,
      duration: 3,
      trackId: v2.id,
      mediaId: '',
      text: 'Chapter one',
    );
    ids.add('title');
  }
  final template = e.captureTemplate(name: 'Section bumper', clipIds: ids);
  expect(template, isNotNull);
  return (e, template!);
}

void main() {
  group('capture', () {
    test('stores relative times, lanes, transitions and media', () {
      final (source, t) = authoredTemplate();

      expect(t.clips.length, 3);
      expect(t.transitions.length, 1);
      expect(t.media.single.hash, 'sha256:aaaa');
      // Lanes are offsets, not track ids: V1 is the base, V2 sits one above.
      expect(t.lanes.map((l) => l.offset).toList(), [0, 1]);
      // Everything is relative to the first clip, which started at 0 here.
      final first = t.clips.firstWhere((c) => c['id'] == 'a');
      expect(first['start'], '0/1');
      // A's duration carries the handle the dissolve consumed.
      expect(
        Rt.parse(first['duration'] as String) > s(5),
        isTrue,
        reason: 'transition geometry travels with the clips (TPL-7)',
      );
      expect(source.doc.transitions.length, 1);
    });

    test('proposes a slot per text clip, per media clip, plus duration', () {
      final (_, t) = authoredTemplate();
      expect(
        t.slots.where((s) => s.kind == SlotKind.text).single.defaultValue,
        'Chapter one',
      );
      expect(t.slots.where((s) => s.kind == SlotKind.media).length, 2);
      expect(t.slots.where((s) => s.kind == SlotKind.duration).length, 1);
    });

    test('drops transitions whose other side is not selected', () {
      final (source, _) = authoredTemplate(withText: false);
      final partial = source.captureTemplate(name: 'Half', clipIds: ['a']);
      expect(partial!.transitions, isEmpty);
    });

    test('round-trips through JSON', () {
      final (_, t) = authoredTemplate();
      final back = ClipTemplate.decode(t.encode());
      expect(back.name, t.name);
      expect(back.clips.length, t.clips.length);
      expect(back.transitions.length, t.transitions.length);
      expect(back.slots.length, t.slots.length);
      expect(back.duration, t.duration);
    });
  });

  group('insert', () {
    test(
      'reproduces geometry and the internal transition, in one undo step',
      () {
        final (_, t) = authoredTemplate();
        final target = harness();

        final result = target.insertTemplate(t, at: s(0));

        expect(result.clipIds.length, 3);
        expect(target.doc.clips.length, 3);
        expect(target.doc.transitions.length, 1);
        // Loading validates `overlap == duration`; assert it directly here.
        final tr = target.doc.transitions.single;
        final a = target.doc.clipById(tr.aClipId)!;
        final b = target.doc.clipById(tr.bClipId)!;
        final overlap = a.end < b.end
            ? a.end.minus(b.start)
            : a.end.minus(b.start);
        expect(overlap, tr.duration);
        expect(
          target.doc.videoTracks.length,
          2,
          reason: 'V2 created for the title',
        );
        expect(target.history.depth, 1);

        target.undo();
        expect(target.doc.clips, isEmpty);
        expect(target.doc.transitions, isEmpty);
      },
    );

    test('resolves media by hash and selects what it inserted', () {
      final (_, t) = authoredTemplate();
      final target = harness();
      final result = target.insertTemplate(t, at: s(0));

      expect(target.doc.media.length, 1, reason: 'matched the existing asset');
      for (final id in result.clipIds) {
        final clip = target.doc.clipById(id)!;
        expect(clip.mediaId, anyOf('', 'asset-1'));
      }
      expect(target.selection, result.clipIds.toSet());
      expect(result.warnings, isEmpty);
    });

    test('falls back to an offline asset when the media is unknown', () {
      final (_, t) = authoredTemplate();
      final target = Edits(
        ProjectDoc.empty('Empty', width: 1920, height: 1080, fps: 30),
      );

      final result = target.insertTemplate(t, at: s(0));

      expect(result.clipIds, isNotEmpty);
      expect(target.doc.media.single.offline, isTrue);
      expect(result.warnings.join(), contains('offline'));
    });

    test('text slot rewrites the clip and leaves the template alone', () {
      final (_, t) = authoredTemplate();
      final slot = t.slots.firstWhere((s) => s.kind == SlotKind.text);
      final target = harness();

      target.insertTemplate(t, at: s(0), slotValues: {slot.id: 'Chapter two'});

      final title = target.doc.clips.firstWhere((c) => c.text != null);
      expect(title.text!.content, 'Chapter two');
      expect(slot.defaultValue, 'Chapter one');
    });

    test('duration slot retimes the chunk proportionally', () {
      final (_, t) = authoredTemplate();
      final slot = t.slots.firstWhere((s) => s.kind == SlotKind.duration);
      final authored = t.duration.seconds;
      final target = harness();

      target.insertTemplate(
        t,
        at: s(0),
        slotValues: {slot.id: (authored / 2).toStringAsFixed(3)},
      );

      final span = target.doc.sequenceDuration.seconds;
      expect(span, closeTo(authored / 2, 0.05));
      expect(
        target.doc.transitions.single.duration.seconds,
        closeTo(0.25, 0.02),
      );
    });

    test('insert mode ripples what is already on the timeline', () {
      final (_, t) = authoredTemplate();
      final target = harness();
      addClip(target, id: 'x', start: 0, duration: 4, sourceIn: 2);
      addClip(target, id: 'y', start: 4, duration: 4, sourceIn: 2);

      target.insertTemplate(t, at: s(4));

      expect(target.doc.clipById('x')!.start, s(0));
      expect(
        target.doc.clipById('y')!.start.seconds,
        closeTo(4 + t.duration.seconds, 0.001),
      );
    });

    test('overwrite mode clears the range instead of pushing', () {
      final (_, t) = authoredTemplate(withText: false);
      final target = harness();
      addClip(target, id: 'x', start: 0, duration: 20, sourceIn: 0);

      target.insertTemplate(t, at: s(4), mode: DropMode.overwrite);

      final x = target.doc.clipById('x')!;
      expect(x.duration, s(4));
      expect(target.doc.sequenceDuration.seconds, closeTo(20, 0.6));
    });
  });

  group('edge transitions', () {
    test('joins the neighbours on both sides', () {
      final (_, t) = authoredTemplate(withText: false);
      t.edgeIn.enabled = true;
      t.edgeOut
        ..enabled = true
        ..type = 'dipToBlack';
      final target = harness();
      addClip(target, id: 'x', start: 0, duration: 4, sourceIn: 2);
      addClip(target, id: 'y', start: 4, duration: 4, sourceIn: 2);

      final result = target.insertTemplate(t, at: s(4));

      expect(result.edgeInId, isNotNull);
      expect(result.edgeOutId, isNotNull);
      expect(target.doc.transitionById(result.edgeOutId!)!.type, 'dipToBlack');
      // Internal dissolve plus the two edges.
      expect(target.doc.transitions.length, 3);
      expect(result.warnings, isEmpty);
      expect(target.history.depth, 1, reason: 'edges join the same undo step');
    });

    test('per-insert override beats the stored spec', () {
      final (_, t) = authoredTemplate(withText: false);
      final target = harness();
      addClip(target, id: 'x', start: 0, duration: 4, sourceIn: 2);

      final result = target.insertTemplate(
        t,
        at: s(4),
        edgeIn: TemplateEdge(enabled: true, type: 'zoomIn', duration: s(1)),
      );

      final tr = target.doc.transitionById(result.edgeInId!)!;
      expect(tr.type, 'zoomIn');
      expect(tr.duration, s(1));
    });

    test('warns and continues when a neighbour has no handles', () {
      final (_, t) = authoredTemplate(withText: false);
      t.edgeIn.enabled = true;
      // Template head with no handles either: nothing can pay for the overlap.
      final head = t.clips.firstWhere((c) => c['id'] == 'a');
      head['sourceIn'] = '0/1';
      final target = harness();
      // x consumes the asset to its very end: no tail handles.
      addClip(target, id: 'x', start: 0, duration: 20, sourceIn: 0);

      final result = target.insertTemplate(t, at: s(20));

      expect(result.edgeInId, isNull);
      expect(result.clipIds, isNotEmpty, reason: 'insert still completes');
      expect(result.warnings.join(), contains('Opening transition skipped'));
    });

    test('an edge with no neighbour is skipped silently', () {
      final (_, t) = authoredTemplate(withText: false);
      t.edgeIn.enabled = true;
      t.edgeOut.enabled = true;
      final target = harness();

      final result = target.insertTemplate(t, at: s(0));

      expect(result.edgeInId, isNull);
      expect(result.edgeOutId, isNull);
      expect(result.warnings, isEmpty);
    });
  });

  group('library', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('cc-templates');
      ProjectRepository.rootOverride = root;
      TemplateLibrary.instance.resetForTest();
    });

    tearDown(() async {
      ProjectRepository.rootOverride = null;
      if (root.existsSync()) await root.delete(recursive: true);
    });

    test('saves, lists and deletes', () async {
      final (_, t) = authoredTemplate();
      final library = TemplateLibrary.instance;

      final file = await library.save(t);
      expect(file.existsSync(), isTrue);
      expect(file.path, endsWith('.$kTemplateExtension'));

      library.resetForTest();
      await library.refresh();
      expect(library.templates.single.name, 'Section bumper');
      expect(library.unreadableCount, 0);

      await library.delete(library.templates.single);
      expect(library.templates, isEmpty);
      expect(file.existsSync(), isFalse);
    });

    test('skips unreadable files instead of failing the list', () async {
      final dir = await TemplateLibrary.directory();
      File(
        '${dir.path}${Platform.pathSeparator}broken.$kTemplateExtension',
      ).writeAsStringSync('{not json');
      final (_, t) = authoredTemplate();
      await TemplateLibrary.instance.save(t);

      await TemplateLibrary.instance.refresh();

      expect(TemplateLibrary.instance.templates.length, 1);
      expect(TemplateLibrary.instance.unreadableCount, 1);
    });

    test('rename moves the file', () async {
      final (_, t) = authoredTemplate();
      final library = TemplateLibrary.instance;
      final original = await library.save(t);

      await library.rename(t, 'Chapter card');

      expect(original.existsSync(), isFalse);
      expect(File(t.filePath!).existsSync(), isTrue);
      expect(t.name, 'Chapter card');
    });
  });
}
