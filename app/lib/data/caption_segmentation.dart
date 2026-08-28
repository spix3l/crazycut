import 'dart:math' as math;

import 'package:crazycut_app/data/caption.dart';
import 'package:crazycut_app/data/caption_report.dart';
import 'package:crazycut_app/data/transcript.dart';
import 'package:crazycut_app/models/rational.dart';

class CaptionSegmentationOptions {
  const CaptionSegmentationOptions({
    this.maxCharactersPerLine = 42,
    this.maxLines = 2,
    this.minDurationSeconds = 0.8,
    this.maxDurationSeconds = 6,
    this.maxCharactersPerSecond = 20,
    this.silenceBreakSeconds = 0.65,
    this.sequenceOffset = const Duration(),
  }) : assert(maxCharactersPerLine > 0),
       assert(maxLines > 0),
       assert(minDurationSeconds > 0),
       assert(maxDurationSeconds >= minDurationSeconds),
       assert(maxCharactersPerSecond > 0),
       assert(silenceBreakSeconds >= 0);

  final int maxCharactersPerLine;
  final int maxLines;
  final double minDurationSeconds;
  final double maxDurationSeconds;
  final double maxCharactersPerSecond;
  final double silenceBreakSeconds;
  final Duration sequenceOffset;

  int get maxCharacters => maxCharactersPerLine * maxLines;
}

class CaptionSegmentationResult {
  const CaptionSegmentationResult({
    required this.track,
    this.issues = const [],
  });

  final CaptionTrack track;
  final List<CaptionIssue> issues;
}

/// Converts cached speech segments into editable cues without a network call.
///
/// Word times are estimated uniformly inside each transcript segment because
/// the current transcript cache only stores segment-level timing. They remain
/// useful for highlighted-word captions and can later be replaced by exact
/// recognizer word timing without changing this API.
class CaptionSegmenter {
  const CaptionSegmenter();

  CaptionSegmentationResult convert(
    Transcript transcript, {
    CaptionSegmentationOptions options = const CaptionSegmentationOptions(),
    CaptionIdFactory? idFactory,
    String? trackId,
    String trackName = 'Captions',
  }) {
    final makeId = idFactory ?? captionIdFactory();
    final issues = <CaptionIssue>[];
    final words = <_TimedWord>[];
    final sorted = [...transcript.segments]
      ..sort((a, b) => a.start.compareTo(b.start));
    var previousEnd = 0.0;

    for (var index = 0; index < sorted.length; index++) {
      final segment = sorted[index];
      var start = segment.start;
      var end = segment.end;
      if (!start.isFinite || !end.isFinite) {
        issues.add(
          CaptionIssue(
            message: 'Ignored transcript segment with non-finite timing.',
            severity: CaptionIssueSeverity.error,
            cueNumber: index + 1,
          ),
        );
        continue;
      }
      if (start < 0) {
        start = 0;
        issues.add(
          CaptionIssue(
            message: 'Clamped a negative transcript start to zero.',
            cueNumber: index + 1,
            repaired: true,
          ),
        );
      }
      if (end <= start) {
        end = start + options.minDurationSeconds;
        issues.add(
          CaptionIssue(
            message: 'Extended a transcript segment with invalid duration.',
            cueNumber: index + 1,
            repaired: true,
          ),
        );
      }
      if (start < previousEnd) {
        start = previousEnd;
        if (end <= start) end = start + options.minDurationSeconds;
        issues.add(
          CaptionIssue(
            message: 'Moved an overlapping transcript segment forward.',
            cueNumber: index + 1,
            repaired: true,
          ),
        );
      }
      previousEnd = end;
      final tokens = _tokens(segment.text);
      if (tokens.isEmpty) continue;
      final weights = tokens.map((word) => math.max(1, word.length)).toList();
      final totalWeight = weights.fold<int>(0, (sum, value) => sum + value);
      var cursor = start;
      for (var i = 0; i < tokens.length; i++) {
        final wordEnd =
            i == tokens.length - 1
                ? end
                : cursor + (end - start) * weights[i] / totalWeight;
        words.add(_TimedWord(tokens[i], cursor, wordEnd));
        cursor = wordEnd;
      }
    }

    final groups = <List<_TimedWord>>[];
    var current = <_TimedWord>[];
    for (final word in words) {
      if (current.isNotEmpty && _mustBreak(current, word, options)) {
        groups.add(current);
        current = <_TimedWord>[];
      }
      current.add(word);
      if (_sentenceEnd.hasMatch(word.text) &&
          word.end - current.first.start >= options.minDurationSeconds) {
        groups.add(current);
        current = <_TimedWord>[];
      }
    }
    if (current.isNotEmpty) groups.add(current);

    final offset = options.sequenceOffset.inMicroseconds / 1000000;
    final items = <CaptionItem>[];
    for (final group in groups) {
      final start = math.max(0.0, group.first.start + offset);
      var end = group.last.end + offset;
      if (end - start < options.minDurationSeconds) {
        end = start + options.minDurationSeconds;
      }
      items.add(
        CaptionItem(
          id: makeId(),
          start: Rt.fromSeconds(start),
          duration: Rt.fromSeconds(end - start),
          text: _wrap(group.map((word) => word.text).join(' '), options),
          words: [
            for (final word in group)
              CaptionWord(
                id: makeId(),
                start: Rt.fromSeconds(math.max(0, word.start + offset)),
                end: Rt.fromSeconds(math.max(0, word.end + offset)),
                text: word.text,
              ),
          ],
        ),
      );
    }

    return CaptionSegmentationResult(
      track: CaptionTrack(
        id: trackId ?? makeId(),
        name: trackName,
        language: transcript.language.isEmpty ? 'und' : transcript.language,
        items: items,
      ),
      issues: issues,
    );
  }

  static bool _mustBreak(
    List<_TimedWord> current,
    _TimedWord next,
    CaptionSegmentationOptions options,
  ) {
    final gap = next.start - current.last.end;
    final textLength =
        current.fold<int>(0, (sum, word) => sum + word.text.length) +
        current.length +
        next.text.length;
    final duration = next.end - current.first.start;
    final readingSpeed = textLength / math.max(duration, 0.001);
    return gap >= options.silenceBreakSeconds ||
        textLength > options.maxCharacters ||
        duration > options.maxDurationSeconds ||
        (readingSpeed > options.maxCharactersPerSecond &&
            current.last.end - current.first.start >=
                options.minDurationSeconds);
  }

  static final _sentenceEnd = RegExp(r'[.!?][\"\u2019\u201d]?$');

  static List<String> _tokens(String text) =>
      text
          .trim()
          .split(RegExp(r'\s+'))
          .where((word) => word.isNotEmpty)
          .toList();

  static String _wrap(String text, CaptionSegmentationOptions options) {
    if (text.length <= options.maxCharactersPerLine) return text;
    final words = text.split(' ');
    final lines = <String>[];
    var line = '';
    for (final word in words) {
      final candidate = line.isEmpty ? word : '$line $word';
      if (candidate.length > options.maxCharactersPerLine && line.isNotEmpty) {
        lines.add(line);
        line = word;
      } else {
        line = candidate;
      }
    }
    if (line.isNotEmpty) lines.add(line);
    return lines.join('\n');
  }
}

class _TimedWord {
  const _TimedWord(this.text, this.start, this.end);
  final String text;
  final double start;
  final double end;
}
