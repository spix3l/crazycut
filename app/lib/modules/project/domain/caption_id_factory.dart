part of 'caption_report.dart';

typedef CaptionIdFactory = String Function();

CaptionIdFactory captionIdFactory([String prefix = 'caption']) {
  var next = 0;
  final seed = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  return () => '$prefix-$seed-${next++}';
}
