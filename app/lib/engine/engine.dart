import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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

typedef _AbiVersionNative = ffi.Int32 Function();
typedef _AbiVersionDart = int Function();

typedef _EngineCreateNative = ffi.Pointer<ffi.Void> Function();
typedef _EngineCreateDart = ffi.Pointer<ffi.Void> Function();

typedef _EngineDestroyNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _EngineDestroyDart = void Function(ffi.Pointer<ffi.Void>);

typedef _LastErrorNative = ffi.Pointer<Utf8> Function();
typedef _LastErrorDart = ffi.Pointer<Utf8> Function();

typedef _ProbeFileNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Pointer<ffi.Pointer<Utf8>>);
typedef _ProbeFileDart = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>,
    ffi.Pointer<ffi.Pointer<Utf8>>);

typedef _ExtractThumbnailNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Double, ffi.Int32,
    ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Int32>);
typedef _ExtractThumbnailDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, double, int,
    ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Int32>);

typedef _ExtractFrameRgbaNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Double, ffi.Int32,
    ffi.Pointer<ffi.Int32>, ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Pointer<ffi.Uint8>>);
typedef _ExtractFrameRgbaDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, double, int,
    ffi.Pointer<ffi.Int32>, ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Pointer<ffi.Uint8>>);

typedef _BufferFreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>);
typedef _BufferFreeDart = void Function(ffi.Pointer<ffi.Uint8>);

class CrazyCutEngine {
  CrazyCutEngine._() {
    _lib = _openLibrary();
  }

  static CrazyCutEngine? _instance;

  static CrazyCutEngine get instance => _instance ??= CrazyCutEngine._();

  late final ffi.DynamicLibrary _lib;

  late final _AbiVersionDart _abiVersion =
      _lib.lookupFunction<_AbiVersionNative, _AbiVersionDart>('cc_abi_version');
  late final _EngineCreateDart _create =
      _lib.lookupFunction<_EngineCreateNative, _EngineCreateDart>('cc_engine_create');
  late final _EngineDestroyDart _destroy =
      _lib.lookupFunction<_EngineDestroyNative, _EngineDestroyDart>('cc_engine_destroy');
  late final _LastErrorDart _lastError =
      _lib.lookupFunction<_LastErrorNative, _LastErrorDart>('cc_last_error');
  late final _ProbeFileDart _probeFile =
      _lib.lookupFunction<_ProbeFileNative, _ProbeFileDart>('cc_probe_file');
  late final _ExtractThumbnailDart _extractThumbnail = _lib
      .lookupFunction<_ExtractThumbnailNative, _ExtractThumbnailDart>(
          'cc_extract_thumbnail');
  late final _ExtractFrameRgbaDart _extractFrameRgba = _lib
      .lookupFunction<_ExtractFrameRgbaNative, _ExtractFrameRgbaDart>(
          'cc_extract_frame_rgba');
  late final _BufferFreeDart _bufferFree =
      _lib.lookupFunction<_BufferFreeNative, _BufferFreeDart>('cc_buffer_free');

  static const int expectedAbiVersion = 1;

  ffi.Pointer<ffi.Void>? _handle;

  void close() {
    final h = _handle;
    if (h != null) {
      _destroy(h);
      _handle = null;
    }
  }

  ffi.Pointer<ffi.Void> get _engine {
    return _handle ??= () {
      const expected = expectedAbiVersion;
      final actual = _abiVersion();
      if (actual != expected) {
        throw EngineException(-1,
            'ABI mismatch: engine $actual, bindings $expected. Rebuild engine.');
      }
      return _create();
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
    final ptr = _lastError();
    if (ptr == ffi.nullptr) return '';
    return ptr.toDartString();
  }

  ProbeResult probeFile(String path) {
    final pathPtr = path.toNativeUtf8();
    final outJson = calloc<ffi.Pointer<Utf8>>();
    try {
      final code = _probeFile(_engine, pathPtr, outJson);
      if (code != 0) {
        throw EngineException(code, _takeLastError());
      }
      final jsonStr = outJson.value.toDartString();
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
      final code = _extractThumbnail(_engine, pathPtr, seconds, width, outBuf, outLen);
      if (code != 0) {
        throw EngineException(code, _takeLastError());
      }
      final len = outLen.value;
      final bytes = Uint8List.fromList(outBuf.value.asTypedList(len));
      _bufferFree(outBuf.value);
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
      final code =
          _extractFrameRgba(_engine, pathPtr, seconds, width, outW, outH, outBuf);
      if (code != 0) {
        throw EngineException(code, _takeLastError());
      }
      final w = outW.value;
      final h = outH.value;
      final bytes = Uint8List.fromList(outBuf.value.asTypedList(w * h * 4));
      _bufferFree(outBuf.value);
      return RawFrame(w, h, bytes);
    } finally {
      calloc.free(pathPtr);
      calloc.free(outW);
      calloc.free(outH);
      calloc.free(outBuf);
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
