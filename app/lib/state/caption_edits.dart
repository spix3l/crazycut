import 'package:flutter/foundation.dart';

import 'package:crazycut_app/data/caption.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/timeline_edits.dart';

/// Undoable editing operations for the typed caption model.
///
/// Caption edits snapshot one track per user action. This keeps text, cue
/// timing, word timing and shared style atomic without teaching the command
/// stack about every caption field individually.
mixin CaptionEdits on TimelineEdits, ChangeNotifier {
  String? selectedCaptionTrackId;
  String? selectedCaptionItemId;

  CaptionTrack? get selectedCaptionTrack {
    final id = selectedCaptionTrackId;
    if (id == null) return null;
    for (final track in doc.captionTracks) {
      if (track.id == id) return track;
    }
    return null;
  }

  CaptionItem? get selectedCaptionItem {
    final id = selectedCaptionItemId;
    final track = selectedCaptionTrack;
    if (id == null || track == null) return null;
    for (final item in track.items) {
      if (item.id == id) return item;
    }
    return null;
  }

  void selectCaption(String? trackId, String? itemId, {bool seek = false}) {
    final track = doc.captionTrackById(trackId ?? '');
    final item =
        track?.items.where((candidate) => candidate.id == itemId).firstOrNull;
    selectedCaptionTrackId = track?.id;
    selectedCaptionItemId = item?.id;
    if (item != null) {
      selection.clear();
      if (seek) seekToCaption(item);
    }
    notifyListeners();
  }

  /// Implemented by [EditorController]; kept abstract so this mixin remains
  /// usable in focused state tests.
  void seekToCaption(CaptionItem item);

  CaptionTrack addCaptionTrack({
    String name = 'Captions',
    String language = 'und',
  }) {
    late CaptionTrack created;
    runEdit('Add caption track', (tx) {
      created = CaptionTrack(id: generateId(), name: name, language: language);
      tx.captionTrack(created.id);
      doc.captionTracks.add(created);
    });
    selectedCaptionTrackId = created.id;
    selectedCaptionItemId = null;
    notifyListeners();
    return created;
  }

  /// Adds a fully populated track as one undoable operation. Automatic
  /// captions use this so a single undo removes the entire generated result.
  CaptionTrack addCaptionTrackFrom(CaptionTrack track) {
    runEdit('Generate captions', (tx) {
      tx.captionTrack(track.id);
      doc.captionTracks.add(track);
    });
    selectedCaptionTrackId = track.id;
    selectedCaptionItemId = track.items.firstOrNull?.id;
    selection.clear();
    notifyListeners();
    return track;
  }

  void deleteCaptionTrack(String trackId) {
    final track = doc.captionTrackById(trackId);
    if (track == null) return;
    runEdit('Delete caption track', (tx) {
      tx.captionTrack(trackId);
      doc.captionTracks.remove(track);
    });
    if (selectedCaptionTrackId == trackId) {
      selectedCaptionTrackId = null;
      selectedCaptionItemId = null;
    }
    notifyListeners();
  }

  CaptionItem? addCaptionItem({String text = 'New caption', Rt? at}) {
    final track =
        selectedCaptionTrack ??
        (doc.captionTracks.isEmpty
            ? addCaptionTrack()
            : doc.captionTracks.first);
    final ordered = [...track.items]
      ..sort((a, b) => a.start.compareTo(b.start));
    var start = quantiseToFrame(at ?? playhead).atLeast(Rt.zero());
    final occupied =
        ordered
            .where((item) => item.start <= start && item.end > start)
            .firstOrNull;
    if (occupied != null) start = occupied.end;
    final next = ordered.where((item) => item.start >= start).firstOrNull;
    var duration = Rt.fromSeconds(2);
    if (next != null && start.plus(duration) > next.start) {
      duration = next.start.minus(start);
    }
    if (duration < frameDuration) return null;

    late CaptionItem created;
    runEdit('Add caption', (tx) {
      tx.captionTrack(track.id);
      created = CaptionItem(
        id: generateId(),
        start: start,
        duration: duration,
        text: text,
      );
      track.items.add(created);
      track.items.sort((a, b) => a.start.compareTo(b.start));
    });
    selectCaption(track.id, created.id, seek: true);
    return created;
  }

  void updateCaptionText(String trackId, String itemId, String text) {
    final found = _find(trackId, itemId);
    if (found == null || found.$2.text == text) return;
    runEdit('Edit caption text', (tx) {
      tx.captionTrack(trackId);
      found.$2.text = text;
      // Corrected text no longer has trustworthy word-level correspondence.
      found.$2.words.clear();
    });
  }

  void updateCaptionSpeaker(String trackId, String itemId, String? speaker) {
    final found = _find(trackId, itemId);
    final value = speaker?.trim();
    final normalized = value == null || value.isEmpty ? null : value;
    if (found == null || found.$2.speaker == normalized) return;
    runEdit('Edit caption speaker', (tx) {
      tx.captionTrack(trackId);
      found.$2.speaker = normalized;
    });
  }

  bool splitCaption(String trackId, String itemId, Rt at, {int? textOffset}) {
    final found = _find(trackId, itemId);
    if (found == null) return false;
    final track = found.$1;
    final item = found.$2;
    final split = quantiseToFrame(at);
    if (split.minus(item.start) < frameDuration ||
        item.end.minus(split) < frameDuration) {
      return false;
    }
    final offset = (textOffset ??
            _naturalSplit(
              item.text,
              split.minus(item.start).seconds / item.duration.seconds,
            ))
        .clamp(0, item.text.length);
    final leftText = item.text.substring(0, offset).trim();
    final rightText = item.text.substring(offset).trim();
    final oldEnd = item.end;
    late CaptionItem right;
    runEdit('Split caption', (tx) {
      tx.captionTrack(trackId);
      item.duration = split.minus(item.start);
      item.text = leftText;
      final rightWords =
          item.words.where((word) => word.start >= split).toList();
      item.words.removeWhere((word) => word.start >= split);
      right = CaptionItem(
        id: generateId(),
        start: split,
        duration: oldEnd.minus(split),
        text: rightText,
        speaker: item.speaker,
        words: rightWords,
      );
      track.items.add(right);
      track.items.sort((a, b) => a.start.compareTo(b.start));
    });
    selectCaption(trackId, right.id, seek: true);
    return true;
  }

  bool mergeCaptionWithNext(String trackId, String itemId) {
    final found = _find(trackId, itemId);
    if (found == null) return false;
    final track = found.$1;
    final items = [...track.items]..sort((a, b) => a.start.compareTo(b.start));
    final index = items.indexWhere((item) => item.id == itemId);
    if (index < 0 || index == items.length - 1) return false;
    final item = items[index];
    final next = items[index + 1];
    runEdit('Merge captions', (tx) {
      tx.captionTrack(trackId);
      item.duration = next.end.minus(item.start);
      item.text = [
        item.text.trim(),
        next.text.trim(),
      ].where((part) => part.isNotEmpty).join(' ');
      item.words.addAll(next.words);
      track.items.removeWhere((candidate) => candidate.id == next.id);
    });
    selectCaption(trackId, item.id);
    return true;
  }

  bool nudgeCaption(String trackId, String itemId, int frames) {
    if (frames == 0) return false;
    final found = _find(trackId, itemId);
    if (found == null) return false;
    final track = found.$1;
    final item = found.$2;
    final items = [...track.items]..sort((a, b) => a.start.compareTo(b.start));
    final index = items.indexWhere((candidate) => candidate.id == itemId);
    final minStart = index <= 0 ? Rt.zero() : items[index - 1].end;
    final maxStart =
        index == items.length - 1
            ? null
            : items[index + 1].start.minus(item.duration);
    final delta = Rt(frameDuration.num * frames, frameDuration.den);
    var start = item.start.plus(delta).atLeast(minStart);
    if (maxStart != null && start > maxStart) start = maxStart;
    if (start == item.start) return false;
    final actual = start.minus(item.start);
    runEdit('Nudge caption', (tx) {
      tx.captionTrack(trackId);
      item.start = start;
      for (final word in item.words) {
        word.start = word.start.plus(actual);
        word.end = word.end.plus(actual);
      }
    });
    return true;
  }

  bool retimeCaption(String trackId, String itemId, {Rt? start, Rt? duration}) {
    final found = _find(trackId, itemId);
    if (found == null) return false;
    final track = found.$1;
    final item = found.$2;
    final items = [...track.items]..sort((a, b) => a.start.compareTo(b.start));
    final index = items.indexWhere((candidate) => candidate.id == itemId);
    final minStart = index <= 0 ? Rt.zero() : items[index - 1].end;
    final nextStart = index == items.length - 1 ? null : items[index + 1].start;
    var targetStart = quantiseToFrame(start ?? item.start).atLeast(minStart);
    var targetDuration = quantiseToFrame(
      duration ?? item.duration,
    ).atLeast(frameDuration);
    if (nextStart != null) {
      final latestStart = nextStart.minus(frameDuration);
      if (targetStart > latestStart) targetStart = latestStart;
      final available = nextStart.minus(targetStart);
      if (targetDuration > available) targetDuration = available;
    }
    if (targetStart == item.start && targetDuration == item.duration) {
      return false;
    }
    final shift = targetStart.minus(item.start);
    runEdit('Retime caption', (tx) {
      tx.captionTrack(trackId);
      item.start = targetStart;
      item.duration = targetDuration;
      for (final word in item.words) {
        word.start = word.start.plus(shift).clampTo(targetStart, item.end);
        word.end = word.end.plus(shift).clampTo(word.start, item.end);
      }
      item.words.removeWhere((word) => word.end <= word.start);
    });
    return true;
  }

  void updateCaptionStyle(
    String trackId, {
    String? preset,
    double? fontSize,
    String? alignment,
    double? positionY,
    double? maxWidth,
    bool? highlightWords,
  }) {
    final track = doc.captionTrackById(trackId);
    if (track == null) return;
    runEdit('Style captions', (tx) {
      tx.captionTrack(trackId);
      if (preset != null) track.style.preset = preset;
      if (fontSize != null) track.style.fontSize = fontSize.clamp(12, 160);
      if (alignment != null) track.style.alignment = alignment;
      if (positionY != null) {
        track.style.positionY = positionY.clamp(0.05, 0.95);
      }
      if (maxWidth != null) track.style.maxWidth = maxWidth.clamp(0.2, 1);
      if (highlightWords != null) track.style.highlightWords = highlightWords;
    });
  }

  (CaptionTrack, CaptionItem)? _find(String trackId, String itemId) {
    final track = doc.captionTrackById(trackId);
    if (track == null) return null;
    for (final item in track.items) {
      if (item.id == itemId) return (track, item);
    }
    return null;
  }

  static int _naturalSplit(String text, double fraction) {
    if (text.isEmpty) return 0;
    final target = (text.length * fraction.clamp(0.0, 1.0)).round();
    for (var distance = 0; distance < text.length; distance++) {
      final left = target - distance;
      if (left > 0 && left < text.length && text[left].trim().isEmpty) {
        return left;
      }
      final right = target + distance;
      if (right > 0 && right < text.length && text[right].trim().isEmpty) {
        return right;
      }
    }
    return target;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
