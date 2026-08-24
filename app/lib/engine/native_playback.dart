import 'dart:io';

import 'package:flutter/services.dart';

import 'package:crazycut_app/engine/engine.dart';

class NativePlayback {
  NativePlayback._();

  static const MethodChannel _channel = MethodChannel('dev.crazycut/playback');

  static final bool supported = Platform.isMacOS || Platform.isWindows;

  static int? textureId;
  static double duration = 0;
  static double fps = 30;
  static String? openedMedia;

  static String? resolveEngineLib() {
    for (final candidate in PlatformHelper.engineLibCandidates()) {
      if (candidate.isEmpty) continue;
      final f = File(candidate);
      if (f.existsSync()) return f.absolute.path;
    }
    return null;
  }

  static Future<bool> open(String mediaPath) async {
    if (!supported) return false;
    final lib = resolveEngineLib();
    if (lib == null) return false;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'open',
        {'engineLib': lib, 'media': mediaPath},
      );
      textureId = (result?['textureId'] as num?)?.toInt();
      duration = ((result?['duration'] as num?) ?? 0).toDouble();
      fps = ((result?['fps'] as num?) ?? 30).toDouble();
      openedMedia = mediaPath;
      return textureId != null && textureId! >= 0;
    } on PlatformException {
      return false; // native side unavailable
    }
  }

  static Future<void> play() async {
    try {
      await _channel.invokeMethod('play');
    } on PlatformException {
      // channel unavailable outside native runner
    }
  }

  static Future<void> pause() async {
    try {
      await _channel.invokeMethod('pause');
    } on PlatformException {
      // channel unavailable outside native runner
    }
  }

  static Future<void> seek(double seconds) async {
    try {
      await _channel.invokeMethod('seek', {'seconds': seconds});
    } on PlatformException {
      // channel unavailable outside native runner
    }
  }

  static Future<double> position() async {
    try {
      return ((await _channel.invokeMethod<double>('position')) ?? 0).toDouble();
    } on PlatformException {
      return 0;
    }
  }

  static Future<bool> isPlaying() async {
    try {
      return (await _channel.invokeMethod<bool>('isPlaying')) ?? false;
    } on PlatformException {
      return false; // native side unavailable
    }
  }

  static Future<void> disposePlayer() async {
    try {
      await _channel.invokeMethod('dispose');
    } on PlatformException {
      // channel unavailable outside native runner
    }
    textureId = null;
    openedMedia = null;
  }
}
