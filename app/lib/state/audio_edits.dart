import 'dart:math' as math;

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/commands.dart';
import 'package:crazycut_app/state/timeline_edits.dart';

/// Audio editing operations (M3 / AUD-*). Split from [TimelineEdits] so the
/// timeline mixin stays about geometry and this stays about level, balance and
/// structure; both run through the same command stack, so every operation here
/// is a single undo step.
mixin AudioEdits on TimelineEdits {
  /// dB ↔ linear helpers. The UI speaks dB (AUD-1), the document stores linear
  /// gain, and −∞ is exactly zero rather than a very small number.
  static double dbToLinear(double db) =>
      db <= kSilenceDb ? 0.0 : math.pow(10, db / 20).toDouble();

  static double linearToDb(double linear) =>
      linear <= 0 ? kSilenceDb : 20 * (math.log(linear) / math.ln10);

  /// The bottom of the fader, shown as −∞.
  static const double kSilenceDb = -48.0;

  // --- Per-clip level (AUD-1/3) ---------------------------------------------

  void setClipVolume(String clipId, double linear) {
    final clip = _audioClip(clipId);
    final value = linear.clamp(0.0, 4.0);
    if (clip == null || clip.volume == value) return;
    runEdit('Clip volume', (tx) {
      tx.clip(clipId);
      clip.volume = value;
    });
  }

  void setClipVolumeDb(String clipId, double db) =>
      setClipVolume(clipId, dbToLinear(db.clamp(kSilenceDb, 12.0)));

  void setClipPan(String clipId, double pan) {
    final clip = _audioClip(clipId);
    final value = pan.clamp(-1.0, 1.0);
    if (clip == null || clip.pan == value) return;
    runEdit('Clip pan', (tx) {
      tx.clip(clipId);
      clip.pan = value;
    });
  }

  void setClipMuted(String clipId, bool muted) {
    final clip = _audioClip(clipId);
    if (clip == null || clip.mute == muted) return;
    runEdit(muted ? 'Mute clip' : 'Unmute clip', (tx) {
      tx.clip(clipId);
      clip.mute = muted;
    });
  }

  // --- Fades (AUD-2) --------------------------------------------------------

  /// Sets a fade handle. Fades are clamped so the two together never exceed
  /// the clip, which is what dragging the corner handles enforces visually.
  void setClipFade(
    String clipId, {
    required bool fadeIn,
    required Rt duration,
    String? curve,
  }) {
    final clip = _audioClip(clipId);
    if (clip == null) return;
    final other = fadeIn ? clip.fadeOut.duration : clip.fadeIn.duration;
    var wanted = duration < Rt.zero() ? Rt.zero() : duration;
    final room = clip.duration.minus(other);
    if (wanted > room) wanted = room < Rt.zero() ? Rt.zero() : room;

    final target = fadeIn ? clip.fadeIn : clip.fadeOut;
    if (target.duration == wanted && (curve == null || target.curve == curve)) {
      return;
    }
    runEdit(fadeIn ? 'Fade in' : 'Fade out', (tx) {
      tx.clip(clipId);
      target.duration = wanted;
      if (curve != null) target.curve = curve;
    });
  }

  void setFadeCurve(String clipId, {required bool fadeIn, required String curve}) {
    final clip = _audioClip(clipId);
    if (clip == null) return;
    final target = fadeIn ? clip.fadeIn : clip.fadeOut;
    if (target.curve == curve) return;
    runEdit('Fade curve', (tx) {
      tx.clip(clipId);
      target.curve = curve;
    });
  }

  // --- Normalize (AUD-5) ----------------------------------------------------

  /// Applies the gain that brings the clip's peak to [targetDbFs]. The peak
  /// scan happens in the caller (it needs the engine); this records the result
  /// as a plain static gain so the document stays declarative.
  void applyNormalizedGain(String clipId, double peak,
      {double targetDbFs = -1.0}) {
    if (peak <= 0) return;
    final target = dbToLinear(targetDbFs);
    setClipVolume(clipId, (target / peak).clamp(0.0, 4.0));
  }

  // --- Detach / link (AUD-6) ------------------------------------------------

  /// True when the clip carries audio that can be split off.
  bool canDetachAudio(String clipId) {
    final clip = doc.clipById(clipId);
    if (clip == null || clip.text != null) return false;
    final track = doc.trackById(clip.trackId);
    if (track == null || !track.isVideo) return false;
    if (clip.linkedGroup != null) return false;  // already detached
    final asset = doc.assetById(clip.mediaId);
    return asset != null && asset.hasAudio;
  }

  /// Splits the clip's audio onto a free audio track at the same position and
  /// links the two halves (AUD-6). Returns the new audio clip's id.
  String? detachAudio(String clipId) {
    if (!canDetachAudio(clipId)) return null;
    final clip = doc.clipById(clipId)!;
    return runEdit('Detach audio', (tx) {
      final trackId = _freeAudioTrackFor(tx, clip.start, clip.end);
      final group = generateId();
      final audio = clip.cloneWithNewId(
        trackId: trackId,
        start: clip.start,
        linkedGroup: group,
      );
      // Snapshot the id *before* the clip exists: a null "before" is what
      // tells undo to delete it again.
      tx.clip(audio.id);
      // The video half keeps the picture, the audio half keeps the sound.
      audio.text = null;
      audio.effects.clear();
      audio.transform = null;
      doc.clips.add(audio);

      tx.clip(clip.id);
      clip.linkedGroup = group;
      clip.mute = true;  // sound now comes from the detached clip
      return audio.id;
    });
  }

  /// Rejoins a detached pair when they still line up (AUD-6). Returns false
  /// with [lastAudioNotice] set when they have drifted.
  bool relinkAudio(String clipId) {
    final clip = doc.clipById(clipId);
    final group = clip?.linkedGroup;
    if (clip == null || group == null) return false;
    final members = doc.linkedWith(clip);
    if (members.length < 2) return false;

    final video = members.firstWhere(
      (c) => doc.trackById(c.trackId)?.isVideo ?? false,
      orElse: () => clip,
    );
    final audio = members.firstWhere(
      (c) => !(doc.trackById(c.trackId)?.isVideo ?? true),
      orElse: () => clip,
    );
    if (identical(video, audio)) return false;
    if (video.start != audio.start ||
        video.duration != audio.duration ||
        video.sourceIn != audio.sourceIn) {
      lastAudioNotice = 'Clips are out of sync — align them before relinking';
      notifyListeners();
      return false;
    }
    runEdit('Relink audio', (tx) {
      tx.clip(video.id);
      tx.clip(audio.id);
      video.linkedGroup = null;
      video.mute = false;
      doc.clips.remove(audio);
      selection.remove(audio.id);
    });
    return true;
  }

  /// Sync drift of a detached pair, or null when in sync / not detached
  /// (drives the "out of sync" badge, AUD acceptance 2).
  Rt? linkedDrift(String clipId) {
    final clip = doc.clipById(clipId);
    if (clip?.linkedGroup == null) return null;
    final members = doc.linkedWith(clip!);
    if (members.length < 2) return null;
    final video = members.firstWhereOrNullCompat(
        (c) => doc.trackById(c.trackId)?.isVideo ?? false);
    final audio = members.firstWhereOrNullCompat(
        (c) => !(doc.trackById(c.trackId)?.isVideo ?? true));
    if (video == null || audio == null) return null;
    if (video.start == audio.start) return null;
    return video.start.minus(audio.start);
  }

  /// Moves the audio half back under its video half (click-to-sync).
  void syncLinked(String clipId) {
    final drift = linkedDrift(clipId);
    if (drift == null) return;
    final clip = doc.clipById(clipId)!;
    final members = doc.linkedWith(clip);
    final video = members.firstWhereOrNullCompat(
        (c) => doc.trackById(c.trackId)?.isVideo ?? false);
    final audio = members.firstWhereOrNullCompat(
        (c) => !(doc.trackById(c.trackId)?.isVideo ?? true));
    if (video == null || audio == null) return;
    runEdit('Sync linked audio', (tx) {
      tx.clip(audio.id);
      audio.start = video.start;
    });
  }

  // --- Mixer (AUD-10/11) ----------------------------------------------------

  void setTrackGain(String trackId, double linear) {
    final track = doc.trackById(trackId);
    final value = linear.clamp(0.0, 4.0);
    if (track == null || track.gain == value) return;
    runEdit('Track fader', (tx) {
      tx.track(trackId);
      track.gain = value;
    });
  }

  void setTrackGainDb(String trackId, double db) =>
      setTrackGain(trackId, dbToLinear(db.clamp(kSilenceDb, 6.0)));

  void setTrackPan(String trackId, double pan) {
    final track = doc.trackById(trackId);
    final value = pan.clamp(-1.0, 1.0);
    if (track == null || track.pan == value) return;
    runEdit('Track pan', (tx) {
      tx.track(trackId);
      track.pan = value;
    });
  }

  void setMasterGain(double linear) {
    final value = linear.clamp(0.0, 4.0);
    if (doc.settings.master.gain == value) return;
    runEdit('Master fader', (tx) {
      tx.settings();
      doc.settings.master.gain = value;
    });
  }

  void setMasterGainDb(double db) =>
      setMasterGain(dbToLinear(db.clamp(kSilenceDb, 6.0)));

  void setMasterLimiter(bool enabled) {
    if (doc.settings.master.limiter == enabled) return;
    runEdit(enabled ? 'Limiter on' : 'Limiter off', (tx) {
      tx.settings();
      doc.settings.master.limiter = enabled;
    });
  }

  // --- Notices --------------------------------------------------------------

  /// Last toast-worthy message from an audio operation.
  String? lastAudioNotice;

  void clearAudioNotice() {
    if (lastAudioNotice == null) return;
    lastAudioNotice = null;
    notifyListeners();
  }

  // --- Internals ------------------------------------------------------------

  /// Clips carrying audio: anything with media, on any track (a video clip's
  /// audio is edited on the clip itself until it is detached).
  Clip? _audioClip(String clipId) {
    final clip = doc.clipById(clipId);
    if (clip == null || clip.text != null) return null;
    if (_lockedTrack(clip.trackId)) return null;
    return clip;
  }

  bool _lockedTrack(String trackId) =>
      doc.trackById(trackId)?.lock ?? false;

  /// An audio track with room for [start, end), creating one when every
  /// existing track is busy — AUD-8 keeps audio non-overlapping.
  String _freeAudioTrackFor(EditTransaction tx, Rt start, Rt end) {
    for (final track in doc.audioTracks) {
      if (track.lock) continue;
      final busy = doc.clipsOn(track.id).any(
            (c) => c.start < end && c.end > start,
          );
      if (!busy) return track.id;
    }
    return _createAudioTrack(tx).id;
  }

  Track _createAudioTrack(EditTransaction tx) => addTrackIn(tx, 'audio');
}

extension _FirstWhereCompat<T> on List<T> {
  T? firstWhereOrNullCompat(bool Function(T) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}
