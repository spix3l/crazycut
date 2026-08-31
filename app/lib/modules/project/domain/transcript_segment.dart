part of 'transcript.dart';

class TranscriptSegment {
  const TranscriptSegment({
    required this.start,
    required this.end,
    required this.text,
  });

  final double start;
  final double end;
  final String text;

  double get duration => end - start;

  static TranscriptSegment? fromJson(Map<String, dynamic> json) {
    final start = (json['start'] as num?)?.toDouble();
    final end = (json['end'] as num?)?.toDouble();
    final text = json['text'] as String?;
    if (start == null || end == null || text == null) return null;
    if (text.trim().isEmpty) return null;
    return TranscriptSegment(start: start, end: end, text: text.trim());
  }

  Map<String, dynamic> toJson() => {'start': start, 'end': end, 'text': text};
}
