part of 'engine.dart';

class ProbeResult {
  ProbeResult({
    required this.type,
    required this.durationSeconds,
    this.width,
    this.height,
    this.fps,
    this.rotation = 0,
    this.vfr = false,
    this.codec,
    this.hdr = 'none',
    this.hasAudio = false,
    this.raw,
  });

  factory ProbeResult.fromJson(Map<String, dynamic> j) {
    final video = j['video'] as Map<String, dynamic>?;
    final audio = j['audio'] as Map<String, dynamic>?;
    return ProbeResult(
      type: (j['type'] as String?) ?? 'unknown',
      durationSeconds: ((j['durationSeconds'] as num?) ?? 0).toDouble(),
      width: video?['width'] as int?,
      height: video?['height'] as int?,
      fps: video?['fps'] as String?,
      rotation: ((video?['rotation'] as num?) ?? 0).toInt(),
      vfr: (video?['vfr'] as bool?) ?? false,
      codec: video?['codec'] as String? ?? audio?['codec'] as String?,
      hdr: (video?['hdr'] as String?) ?? 'none',
      hasAudio: audio != null,
      raw: j,
    );
  }

  final String type;
  final double durationSeconds;
  final int? width;
  final int? height;
  final String? fps;
  final int rotation;
  final bool vfr;
  final String? codec;
  final String hdr;
  final bool hasAudio;
  final Map<String, dynamic>? raw;
}
