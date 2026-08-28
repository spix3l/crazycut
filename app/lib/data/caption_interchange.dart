import 'dart:math' as math;

import 'package:crazycut_app/data/caption.dart';
import 'package:crazycut_app/data/caption_report.dart';
import 'package:crazycut_app/models/rational.dart';

enum CaptionFormat { srt, webVtt }

class CaptionImportOptions {
  const CaptionImportOptions({
    this.language = 'und',
    this.frameRate = 30,
    this.repairOverlaps = true,
  }) : assert(frameRate > 0);

  final String language;
  final double frameRate;
  final bool repairOverlaps;
}

class CaptionImportResult {
  const CaptionImportResult({
    required this.track,
    required this.format,
    this.issues = const [],
  });

  final CaptionTrack track;
  final CaptionFormat format;
  final List<CaptionIssue> issues;

  bool get hasErrors =>
      issues.any((issue) => issue.severity == CaptionIssueSeverity.error);
  int get repairCount => issues.where((issue) => issue.repaired).length;
}

/// SRT and WebVTT parsing/serialization for caption sidecars and imports.
abstract final class CaptionInterchange {
  static CaptionImportResult parse(
    String source, {
    CaptionFormat? format,
    CaptionImportOptions options = const CaptionImportOptions(),
    CaptionIdFactory? idFactory,
    String? trackId,
    String trackName = 'Captions',
  }) {
    final normalized = _normalize(source);
    final detected =
        format ??
        (normalized.trimLeft().startsWith('WEBVTT')
            ? CaptionFormat.webVtt
            : CaptionFormat.srt);
    return detected == CaptionFormat.srt
        ? importSrt(
          source,
          options: options,
          idFactory: idFactory,
          trackId: trackId,
          trackName: trackName,
        )
        : importWebVtt(
          source,
          options: options,
          idFactory: idFactory,
          trackId: trackId,
          trackName: trackName,
        );
  }

  static CaptionImportResult importSrt(
    String source, {
    CaptionImportOptions options = const CaptionImportOptions(),
    CaptionIdFactory? idFactory,
    String? trackId,
    String trackName = 'Captions',
  }) => _import(
    source,
    format: CaptionFormat.srt,
    options: options,
    idFactory: idFactory,
    trackId: trackId,
    trackName: trackName,
  );

  static CaptionImportResult importWebVtt(
    String source, {
    CaptionImportOptions options = const CaptionImportOptions(),
    CaptionIdFactory? idFactory,
    String? trackId,
    String trackName = 'Captions',
  }) => _import(
    source,
    format: CaptionFormat.webVtt,
    options: options,
    idFactory: idFactory,
    trackId: trackId,
    trackName: trackName,
  );

  static String exportSrt(CaptionTrack track) {
    final out = StringBuffer();
    final cues = [...track.items]..sort((a, b) => a.start.compareTo(b.start));
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      out
        ..writeln(i + 1)
        ..writeln(
          '${_formatTimestamp(cue.start, comma: true)} --> '
          '${_formatTimestamp(cue.end, comma: true)}',
        )
        ..writeln(cue.text.replaceAll('\r', ''))
        ..writeln();
    }
    return out.toString();
  }

  static String exportWebVtt(CaptionTrack track) {
    final out = StringBuffer('WEBVTT\n\n');
    final cues = [...track.items]..sort((a, b) => a.start.compareTo(b.start));
    for (final cue in cues) {
      out.writeln(
        '${_formatTimestamp(cue.start)} --> ${_formatTimestamp(cue.end)}',
      );
      final text = cue.text.replaceAll('\r', '');
      out.writeln(
        cue.speaker == null || cue.speaker!.trim().isEmpty
            ? text
            : '<v ${cue.speaker!.trim()}>$text</v>',
      );
      out.writeln();
    }
    return out.toString();
  }

  static CaptionImportResult _import(
    String source, {
    required CaptionFormat format,
    required CaptionImportOptions options,
    CaptionIdFactory? idFactory,
    String? trackId,
    required String trackName,
  }) {
    final makeId = idFactory ?? captionIdFactory();
    final issues = <CaptionIssue>[];
    var normalized = _normalize(source);
    if (format == CaptionFormat.webVtt) {
      final lines = normalized.split('\n');
      final firstContent = lines.indexWhere((line) => line.trim().isNotEmpty);
      if (firstContent < 0 ||
          !lines[firstContent].trim().startsWith('WEBVTT')) {
        issues.add(
          const CaptionIssue(
            message: 'WebVTT header was missing; cues were imported anyway.',
            repaired: true,
            lineNumber: 1,
          ),
        );
      } else {
        var headerEnd = firstContent;
        while (headerEnd < lines.length && lines[headerEnd].trim().isNotEmpty) {
          lines[headerEnd] = '';
          headerEnd++;
        }
        normalized = lines.join('\n');
      }
    }

    final blocks = _blocks(normalized);
    final parsed = <_ParsedCue>[];
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      final lines = block.text.split('\n');
      if (lines.isEmpty) continue;
      final first = lines.first.trim();
      if (format == CaptionFormat.webVtt &&
          (first == 'STYLE' || first == 'REGION' || first.startsWith('NOTE'))) {
        continue;
      }
      var timingIndex = lines.indexWhere((line) => line.contains('-->'));
      if (timingIndex < 0) {
        issues.add(
          CaptionIssue(
            message: 'Ignored a caption block without a timing line.',
            severity: CaptionIssueSeverity.error,
            cueNumber: index + 1,
            lineNumber: block.line,
          ),
        );
        continue;
      }
      if (format == CaptionFormat.srt && timingIndex > 1) {
        issues.add(
          CaptionIssue(
            message: 'Ignored unexpected lines before an SRT timing line.',
            cueNumber: index + 1,
            lineNumber: block.line,
          ),
        );
      }
      final timing = _parseTiming(lines[timingIndex]);
      if (timing == null) {
        issues.add(
          CaptionIssue(
            message: 'Ignored a caption with an invalid timestamp.',
            severity: CaptionIssueSeverity.error,
            cueNumber: index + 1,
            lineNumber: block.line + timingIndex,
          ),
        );
        continue;
      }
      var text = lines.skip(timingIndex + 1).join('\n').trim();
      if (text.isEmpty) {
        issues.add(
          CaptionIssue(
            message: 'Ignored an empty caption.',
            severity: CaptionIssueSeverity.error,
            cueNumber: index + 1,
            lineNumber: block.line,
          ),
        );
        continue;
      }
      String? speaker;
      if (format == CaptionFormat.webVtt) {
        final voice = RegExp(
          r'^<v(?:\.\S+)*\s+([^>]+)>([\s\S]*?)(?:</v>)?$',
        ).firstMatch(text);
        if (voice != null) {
          speaker = voice.group(1)!.trim();
          text = voice.group(2)!.trim();
        }
      }
      parsed.add(
        _ParsedCue(
          originalNumber: index + 1,
          start: timing.$1,
          end: timing.$2,
          text: text,
          speaker: speaker,
        ),
      );
    }

    parsed.sort((a, b) => a.start.compareTo(b.start));
    final minimum = 1 / options.frameRate;
    var previousEnd = 0.0;
    final items = <CaptionItem>[];
    for (final cue in parsed) {
      var start = cue.start;
      var end = cue.end;
      if (start < 0) {
        start = 0;
        issues.add(
          CaptionIssue(
            message: 'Clamped a negative cue start to zero.',
            cueNumber: cue.originalNumber,
            repaired: true,
          ),
        );
      }
      if (end <= start) {
        end = start + minimum;
        issues.add(
          CaptionIssue(
            message: 'Extended an invalid cue to one frame.',
            cueNumber: cue.originalNumber,
            repaired: true,
          ),
        );
      }
      if (options.repairOverlaps && start < previousEnd) {
        final duration = math.max(minimum, end - start);
        start = previousEnd;
        end = start + duration;
        issues.add(
          CaptionIssue(
            message: 'Moved an overlapping cue after the previous cue.',
            cueNumber: cue.originalNumber,
            repaired: true,
          ),
        );
      }
      if (end - start < minimum) {
        end = start + minimum;
        issues.add(
          CaptionIssue(
            message: 'Extended a short cue to one frame.',
            cueNumber: cue.originalNumber,
            repaired: true,
          ),
        );
      }
      previousEnd = end;
      items.add(
        CaptionItem(
          id: makeId(),
          start: Rt.fromSeconds(start),
          duration: Rt.fromSeconds(end - start),
          text: cue.text,
          speaker: cue.speaker,
        ),
      );
    }

    return CaptionImportResult(
      track: CaptionTrack(
        id: trackId ?? makeId(),
        name: trackName,
        language: options.language.isEmpty ? 'und' : options.language,
        items: items,
      ),
      format: format,
      issues: issues,
    );
  }

  static String _normalize(String source) => source
      .replaceFirst('\ufeff', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');

  static List<_Block> _blocks(String source) {
    final result = <_Block>[];
    final lines = source.split('\n');
    var start = 0;
    var content = <String>[];
    void flush() {
      if (content.any((line) => line.trim().isNotEmpty)) {
        result.add(_Block(content.join('\n').trim(), start + 1));
      }
      content = <String>[];
    }

    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().isEmpty) {
        flush();
        start = i + 1;
      } else {
        if (content.isEmpty) start = i;
        content.add(lines[i]);
      }
    }
    flush();
    return result;
  }

  static (double, double)? _parseTiming(String value) {
    final match = RegExp(
      r'^\s*(\d{1,}:\d{2}:\d{2}[,.]\d{1,3}|\d{1,2}:\d{2}[,.]\d{1,3})\s*-->\s*'
      r'(\d{1,}:\d{2}:\d{2}[,.]\d{1,3}|\d{1,2}:\d{2}[,.]\d{1,3})(?:\s+.*)?$',
    ).firstMatch(value);
    if (match == null) return null;
    final start = _parseTimestamp(match.group(1)!);
    final end = _parseTimestamp(match.group(2)!);
    return start == null || end == null ? null : (start, end);
  }

  static double? _parseTimestamp(String value) {
    final sections = value.replaceAll(',', '.').split(':');
    if (sections.length != 2 && sections.length != 3) return null;
    final hours = sections.length == 3 ? int.tryParse(sections[0]) : 0;
    final minutes = int.tryParse(sections[sections.length - 2]);
    final secondParts = sections.last.split('.');
    if (secondParts.length != 2) return null;
    final seconds = int.tryParse(secondParts[0]);
    final fractionText = secondParts[1].padRight(3, '0');
    final millis = int.tryParse(fractionText.substring(0, 3));
    if (hours == null ||
        minutes == null ||
        seconds == null ||
        millis == null ||
        minutes > 59 ||
        seconds > 59) {
      return null;
    }
    return hours * 3600 + minutes * 60 + seconds + millis / 1000;
  }

  static String _formatTimestamp(Rt time, {bool comma = false}) {
    final totalMillis = math.max(0, (time.seconds * 1000).round());
    final hours = totalMillis ~/ 3600000;
    final minutes = (totalMillis ~/ 60000) % 60;
    final seconds = (totalMillis ~/ 1000) % 60;
    final millis = totalMillis % 1000;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(hours)}:${two(minutes)}:${two(seconds)}'
        '${comma ? ',' : '.'}${millis.toString().padLeft(3, '0')}';
  }
}

class _Block {
  const _Block(this.text, this.line);
  final String text;
  final int line;
}

class _ParsedCue {
  const _ParsedCue({
    required this.originalNumber,
    required this.start,
    required this.end,
    required this.text,
    this.speaker,
  });

  final int originalNumber;
  final double start;
  final double end;
  final String text;
  final String? speaker;
}
