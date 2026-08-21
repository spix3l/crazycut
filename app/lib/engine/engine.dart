import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'crazycut_bindings_generated.dart';

class EngineException implements Exception {
  EngineException(this.code, this.message);
  final int code;
  final String message;

  @override
  String toString() => 'EngineException($code): $message';
}

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

class RawFrame {
  RawFrame(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;
}

class ProjectValidationReport {
  ProjectValidationReport(this.json);
  final Map<String, dynamic> json;
  bool get valid => json['valid'] as bool? ?? false;
  List<dynamic> get issues => json['issues'] as List<dynamic>? ?? const [];
  double get durationSeconds {
    final value = json['duration'] as String? ?? '0/1';
    final parts = value.split('/');
    if (parts.length != 2) return 0;
    return (int.tryParse(parts[0]) ?? 0) / (int.tryParse(parts[1]) ?? 1);
  }
}

class WaveformResult {
  WaveformResult(this.json);
  final Map<String, dynamic> json;
  int get sampleRate => json['sampleRate'] as int;
  int get channels => json['channels'] as int;
  int get peaksPerSecond => json['peaksPerSecond'] as int;
  List<dynamic> get peaks => json['peaks'] as List<dynamic>;
}

class CrazyCutEngine {
  CrazyCutEngine._() {
    _lib = _openLibrary();
  }

  static CrazyCutEngine? _instance;

  static CrazyCutEngine get instance => _instance ??= CrazyCutEngine._();

  late final ffi.DynamicLibrary _lib;
  late final CrazyCutNativeBindings _native = CrazyCutNativeBindings(_lib);

  static const int expectedAbiVersion = 1;

  ffi.Pointer<cc_engine>? _handle;

  void close() {
    final h = _handle;
    if (h != null) {
      _native.cc_engine_destroy(h);
      _handle = null;
    }
  }

  ffi.Pointer<cc_engine> get _engine {
    return _handle ??= () {
      const expected = expectedAbiVersion;
      final actual = _native.cc_abi_version();
      if (actual != expected) {
        throw EngineException(-1,
            'ABI mismatch: engine $actual, bindings $expected. Rebuild engine.');
      }
      return _native.cc_engine_create();
    }();
  }

  static ffi.DynamicLibrary _openLibrary() {
    final candidates = <String>[
      const String.fromEnvironment('CRAZYCUT_ENGINE_LIB'),
      ...PlatformHelper.engineLibCandidates(),
    ];
    for (final candidate in candidates) {
      if (candidate.isEmpty) continue;
      try {
        return ffi.DynamicLibrary.open(candidate);
      } catch (_) {}
    }
    throw EngineException(
        -1, 'libcrazycut not found. Build engine and pass CRAZYCUT_ENGINE_LIB.');
  }

  String _takeLastError() {
    final ptr = _native.cc_last_error();
    if (ptr == ffi.nullptr) return '';
    return ptr.cast<Utf8>().toDartString();
  }

  ProbeResult probeFile(String path) {
    final pathPtr = path.toNativeUtf8();
    final outJson = calloc<ffi.Pointer<ffi.Char>>();
    try {
      final code = _native.cc_probe_file(
          _engine, pathPtr.cast<ffi.Char>(), outJson);
      if (code != 0) {
        throw EngineException(code, _takeLastError());
      }
      final jsonStr = outJson.value.cast<Utf8>().toDartString();
      return ProbeResult.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
    } finally {
      calloc.free(pathPtr);
      calloc.free(outJson);
    }
  }

  Uint8List extractThumbnail(String path, {double seconds = 0, int width = 480}) {
    final pathPtr = path.toNativeUtf8();
    final outBuf = calloc<ffi.Pointer<ffi.Uint8>>();
    final outLen = calloc<ffi.Int32>();
    try {
      final code = _native.cc_extract_thumbnail(
          _engine, pathPtr.cast<ffi.Char>(), seconds, width, outBuf, outLen);
      if (code != 0) {
        throw EngineException(code, _takeLastError());
      }
      final len = outLen.value;
      final bytes = Uint8List.fromList(outBuf.value.asTypedList(len));
      _native.cc_buffer_free(outBuf.value);
      return bytes;
    } finally {
      calloc.free(pathPtr);
      calloc.free(outBuf);
      calloc.free(outLen);
    }
  }

  RawFrame extractFrameRgba(String path, {double seconds = 0, int width = 0}) {
    final pathPtr = path.toNativeUtf8();
    final outW = calloc<ffi.Int32>();
    final outH = calloc<ffi.Int32>();
    final outBuf = calloc<ffi.Pointer<ffi.Uint8>>();
    try {
      final code = _native.cc_extract_frame_rgba(
          _engine, pathPtr.cast<ffi.Char>(), seconds, width, outW, outH, outBuf);
      if (code != 0) {
        throw EngineException(code, _takeLastError());
      }
      final w = outW.value;
      final h = outH.value;
      final bytes = Uint8List.fromList(outBuf.value.asTypedList(w * h * 4));
      _native.cc_buffer_free(outBuf.value);
      return RawFrame(w, h, bytes);
    } finally {
      calloc.free(pathPtr);
      calloc.free(outW);
      calloc.free(outH);
      calloc.free(outBuf);
    }
  }

  ProjectValidationReport setProjectSnapshot(String projectJson,
      {bool repairInvalid = true}) {
    final jsonPtr = projectJson.toNativeUtf8();
    final out = calloc<ffi.Pointer<ffi.Char>>();
    try {
      final code = _native.cc_project_set_snapshot(
          _engine, jsonPtr.cast<ffi.Char>(), repairInvalid ? 1 : 0, out);
      if (code != 0) throw EngineException(code, _takeLastError());
      return ProjectValidationReport(
          jsonDecode(out.value.cast<Utf8>().toDartString()) as Map<String, dynamic>);
    } finally {
      calloc.free(jsonPtr);
      calloc.free(out);
    }
  }

  String get canonicalProjectSnapshot {
    final out = calloc<ffi.Pointer<ffi.Char>>();
    try {
      final code = _native.cc_project_get_snapshot(_engine, out);
      if (code != 0) throw EngineException(code, _takeLastError());
      return out.value.cast<Utf8>().toDartString();
    } finally {
      calloc.free(out);
    }
  }

  double get projectDurationSeconds => _native.cc_project_duration(_engine);

  String hashFile(String path) {
    final pathPtr = path.toNativeUtf8();
    final out = calloc<ffi.Pointer<ffi.Char>>();
    try {
      final code = _native.cc_hash_file(_engine, pathPtr.cast<ffi.Char>(), out);
      if (code != 0) throw EngineException(code, _takeLastError());
      return out.value.cast<Utf8>().toDartString();
    } finally {
      calloc.free(pathPtr);
      calloc.free(out);
    }
  }

  WaveformResult extractWaveform(String path, {int peaksPerSecond = 100}) {
    final pathPtr = path.toNativeUtf8();
    final out = calloc<ffi.Pointer<ffi.Char>>();
    try {
      final code = _native.cc_extract_waveform(
          _engine, pathPtr.cast<ffi.Char>(), peaksPerSecond, out);
      if (code != 0) throw EngineException(code, _takeLastError());
      return WaveformResult(
          jsonDecode(out.value.cast<Utf8>().toDartString()) as Map<String, dynamic>);
    } finally {
      calloc.free(pathPtr);
      calloc.free(out);
    }
  }
}

class PlatformHelper {
  static List<String> engineLibCandidates() {
    return [
      '../engine/build/libcrazycut.dylib',
      '../../engine/build/libcrazycut.dylib',
      '../engine/build/Debug/crazycut.dll',
      '../engine/build/Release/crazycut.dll',
    ];
  }

  static List<String> workerBinCandidates() {
    const defined = String.fromEnvironment('CRAZYCUT_WORKER_BIN');
    if (defined.isNotEmpty) return [defined];
    return [
      '../engine/build/crazycut_worker',
      '../../engine/build/crazycut_worker',
      '../engine/build/Debug/crazycut_worker.exe',
      '../engine/build/Release/crazycut_worker.exe',
    ];
  }
}
