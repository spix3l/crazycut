import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/audio_edits.dart';
import 'package:crazycut_app/state/timeline_edits.dart';

/// Minimal host for the mixins: no engine, no autosave, just the document.
class Edits extends ChangeNotifier with TimelineEdits, AudioEdits {
  Edits(this.doc);

  @override
  final ProjectDoc doc;

  @override
  Rt playhead = Rt.zero();

  @override
  double get fps => doc.settings.fpsValue;

  int dirtyCount = 0;

  @override
  void markDirty() => dirtyCount++;
}

Rt s(double seconds) => Rt.fromSeconds(seconds);

Edits harness({bool hasAudio = true}) {
  final doc = ProjectDoc.empty('Audio', width: 1920, height: 1080, fps: 30);
  doc.media.add(MediaAsset(
    id: 'asset-1',
    name: 'clip.mov',
    path: '/tmp/clip.mov',
    type: 'video',
    duration: s(60),
    hasAudio: hasAudio,
  ));
  return Edits(doc);
}

Clip addClip(Edits e, {String id = 'c1', double start = 0, double duration = 5,
    String? trackId}) {
  final clip = Clip(
    id: id,
    trackId: trackId ?? e.doc.videoTrack()!.id,
    mediaId: 'asset-1',
    label: id,
    start: s(start),
    duration: s(duration),
    sourceIn: Rt.zero(),
  );
  e.doc.clips.add(clip);
  return clip;
}

void main() {
  group('levels (AUD-1/3)', () {
    test('volume is stored linear and read back in dB', () {
      final e = harness();
      addClip(e);
      e.setClipVolumeDb('c1', -6.0);
      expect(e.clipById('c1')!.volume, closeTo(0.501, 0.002));
      expect(AudioEdits.linearToDb(e.clipById('c1')!.volume), closeTo(-6, 0.01));
    });

    test('the bottom of the fader is exactly silent', () {
      final e = harness();
      addClip(e);
      e.setClipVolumeDb('c1', AudioEdits.kSilenceDb);
      expect(e.clipById('c1')!.volume, 0.0);
    });

    test('pan and mute are single undo steps', () {
      final e = harness();
      addClip(e);
      e.setClipPan('c1', 0.5);
      e.setClipMuted('c1', true);
      expect(e.clipById('c1')!.pan, 0.5);
      expect(e.clipById('c1')!.mute, isTrue);
      e.undo();
      expect(e.clipById('c1')!.mute, isFalse);
      expect(e.clipById('c1')!.pan, 0.5);
      e.undo();
      expect(e.clipById('c1')!.pan, 0.0);
    });

    test('a locked track refuses level edits', () {
      final e = harness();
      final clip = addClip(e);
      e.setTrackFlags(clip.trackId, lock: true);
      e.setClipVolume('c1', 0.25);
      expect(e.clipById('c1')!.volume, 1.0);
    });
  });

  group('fades (AUD-2)', () {
    test('fades clamp so the pair never exceeds the clip', () {
      final e = harness();
      addClip(e, duration: 4);
      e.setClipFade('c1', fadeIn: true, duration: s(3));
      e.setClipFade('c1', fadeIn: false, duration: s(3));
      final clip = e.clipById('c1')!;
      expect(clip.fadeIn.duration, s(3));
      // Only one second of room was left for the tail.
      expect(clip.fadeOut.duration, s(1));
    });

    test('a negative drag closes the fade rather than inverting it', () {
      final e = harness();
      addClip(e);
      e.setClipFade('c1', fadeIn: true, duration: s(-2));
      expect(e.clipById('c1')!.fadeIn.duration, Rt.zero());
    });

    test('curve is stored per side', () {
      final e = harness();
      addClip(e);
      e.setFadeCurve('c1', fadeIn: true, curve: 'scurve');
      e.setFadeCurve('c1', fadeIn: false, curve: 'linear');
      expect(e.clipById('c1')!.fadeIn.curve, 'scurve');
      expect(e.clipById('c1')!.fadeOut.curve, 'linear');
    });
  });

  group('normalize (AUD-5)', () {
    test('gain lands the measured peak at −1 dBFS', () {
      final e = harness();
      addClip(e);
      e.applyNormalizedGain('c1', 0.5);
      // −1 dBFS is 0.891; 0.891 / 0.5 = 1.78.
      expect(e.clipById('c1')!.volume, closeTo(1.783, 0.01));
    });

    test('a silent scan changes nothing', () {
      final e = harness();
      addClip(e);
      e.applyNormalizedGain('c1', 0);
      expect(e.clipById('c1')!.volume, 1.0);
    });
  });

  group('detach and link (AUD-6)', () {
    test('detach puts audio on a free audio track and links the pair', () {
      final e = harness();
      addClip(e, duration: 5);
      expect(e.canDetachAudio('c1'), isTrue);

      final audioId = e.detachAudio('c1')!;
      final video = e.clipById('c1')!;
      final audio = e.clipById(audioId)!;

      expect(e.doc.trackById(audio.trackId)!.isVideo, isFalse);
      expect(audio.start, video.start);
      expect(audio.duration, video.duration);
      expect(video.linkedGroup, isNotNull);
      expect(audio.linkedGroup, video.linkedGroup);
      // The picture half goes silent so the sound is not counted twice.
      expect(video.mute, isTrue);
      expect(e.canDetachAudio('c1'), isFalse);
    });

    test('detach is one undo step', () {
      final e = harness();
      addClip(e);
      final before = e.doc.clips.length;
      e.detachAudio('c1');
      expect(e.doc.clips.length, before + 1);
      e.undo();
      expect(e.doc.clips.length, before);
      expect(e.clipById('c1')!.linkedGroup, isNull);
      expect(e.clipById('c1')!.mute, isFalse);
    });

    test('detach onto a busy audio track creates another one', () {
      final e = harness();
      final audioTrack = e.doc.audioTrack()!;
      addClip(e, id: 'blocker', start: 0, duration: 10, trackId: audioTrack.id);
      addClip(e, id: 'c1', start: 2, duration: 5);

      final tracksBefore = e.doc.audioTracks.length;
      final audioId = e.detachAudio('c1')!;
      expect(e.doc.audioTracks.length, tracksBefore + 1);
      expect(e.clipById(audioId)!.trackId, isNot(audioTrack.id));
    });

    test('a clip with no audio stream cannot be detached', () {
      final e = harness(hasAudio: false);
      addClip(e);
      expect(e.canDetachAudio('c1'), isFalse);
      expect(e.detachAudio('c1'), isNull);
    });

    test('drift is reported and click-to-sync realigns', () {
      final e = harness();
      addClip(e, duration: 5);
      final audioId = e.detachAudio('c1')!;
      expect(e.linkedDrift('c1'), isNull);

      e.setClipTiming(audioId, start: s(1));
      expect(e.linkedDrift('c1'), s(-1));

      e.syncLinked('c1');
      expect(e.linkedDrift('c1'), isNull);
      expect(e.clipById(audioId)!.start, e.clipById('c1')!.start);
    });

    test('relink refuses drifted clips and succeeds once aligned', () {
      final e = harness();
      addClip(e, duration: 5);
      final audioId = e.detachAudio('c1')!;
      e.setClipTiming(audioId, start: s(2));

      expect(e.relinkAudio('c1'), isFalse);
      expect(e.lastAudioNotice, contains('out of sync'));

      e.syncLinked('c1');
      expect(e.relinkAudio('c1'), isTrue);
      expect(e.clipById(audioId), isNull);
      expect(e.clipById('c1')!.linkedGroup, isNull);
      expect(e.clipById('c1')!.mute, isFalse);
    });
  });

  group('mixer (AUD-10/11)', () {
    test('track fader and pan round-trip through the document', () {
      final e = harness();
      final track = e.doc.audioTrack()!;
      e.setTrackGainDb(track.id, -6);
      e.setTrackPan(track.id, -0.5);
      expect(e.doc.trackById(track.id)!.gain, closeTo(0.501, 0.002));
      expect(e.doc.trackById(track.id)!.pan, -0.5);

      final reloaded = ProjectDoc.decode(e.doc.encode());
      expect(reloaded.trackById(track.id)!.gain, closeTo(0.501, 0.002));
      expect(reloaded.trackById(track.id)!.pan, -0.5);
    });

    test('master fader and limiter persist and undo', () {
      final e = harness();
      e.setMasterGainDb(-3);
      e.setMasterLimiter(false);
      expect(e.doc.settings.master.gain, closeTo(0.708, 0.002));
      expect(e.doc.settings.master.limiter, isFalse);

      final reloaded = ProjectDoc.decode(e.doc.encode());
      expect(reloaded.settings.master.limiter, isFalse);
      expect(reloaded.settings.master.gain, closeTo(0.708, 0.002));

      e.undo();
      expect(e.doc.settings.master.limiter, isTrue);
    });

    test('the limiter defaults on for a new project', () {
      final e = harness();
      expect(e.doc.settings.master.limiter, isTrue);
      expect(e.doc.settings.master.ceilingDb, -1.0);
    });
  });
}
