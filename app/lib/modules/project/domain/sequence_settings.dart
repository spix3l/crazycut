part of 'project.dart';

class SequenceSettings {
  SequenceSettings({
    required this.width,
    required this.height,
    required this.fps,
    this.audioSampleRate = 48000,
    this.background = '#000000',
    MasterBus? master,
  }) : master = master ?? MasterBus();

  int width;
  int height;
  String fps;
  int audioSampleRate;
  String background;

  /// Master bus: output fader and the safety limiter (AUD-10/11).
  MasterBus master;

  double get fpsValue => Rt.fpsFromString(fps);

  /// One frame of sequence time.
  Rt get frameDuration {
    final r = Rt.parse(fps);
    return Rt(r.den, r.num == 0 ? 1 : r.num);
  }

  SequenceSettings copy() => SequenceSettings(
    width: width,
    height: height,
    fps: fps,
    audioSampleRate: audioSampleRate,
    background: background,
    master: master.copy(),
  );

  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'fps': fps,
    'audioSampleRate': audioSampleRate,
    'background': background,
    'master': master.toJson(),
  };

  static SequenceSettings fromJson(Map<String, dynamic> j) => SequenceSettings(
    width: j['width'] as int,
    height: j['height'] as int,
    fps: j['fps'] as String,
    audioSampleRate: (j['audioSampleRate'] as num?)?.toInt() ?? 48000,
    background: (j['background'] as String?) ?? '#000000',
    master: MasterBus.fromJson(j['master'] as Map<String, dynamic>?),
  );
}
