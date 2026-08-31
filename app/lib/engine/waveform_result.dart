part of 'engine.dart';

class WaveformResult {
  WaveformResult(this.json);
  final Map<String, dynamic> json;
  int get sampleRate => json['sampleRate'] as int;
  int get channels => json['channels'] as int;
  int get peaksPerSecond => json['peaksPerSecond'] as int;
  List<dynamic> get peaks => json['peaks'] as List<dynamic>;
}
