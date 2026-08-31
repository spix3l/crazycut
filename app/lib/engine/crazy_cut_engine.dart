part of 'engine.dart';

class CrazyCutEngine {
  CrazyCutEngine._() {
    _lib = _openLibrary();
  }

  static CrazyCutEngine? _instance;

  static CrazyCutEngine get instance => _instance ??= CrazyCutEngine._();

  late final ffi.DynamicLibrary _lib;
  late final CrazyCutNativeBindings _native = CrazyCutNativeBindings(_lib);

  static const int expectedAbiVersion = 4;

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
  /// One composited frame of the installed project snapshot at [time].
  ///
  /// [mediaPaths] maps asset id to decode path; [textures] maps
  /// `"text:<clipId>"` to pre-rasterized RGBA pixels with their size in
  /// [textureSizes] (TXT-7). This drives the same engine path the export
  /// worker uses per frame, so preview == export by construction.
  RawFrame renderFrameRgba({
    required Rt time,
    required int width,
    required int height,
    Map<String, String> mediaPaths = const {},
    Map<String, Uint8List> textures = const {},
    Map<String, (int, int)> textureSizes = const {},
  }) {
    final keys = calloc<ffi.Pointer<ffi.Char>>(mediaPaths.length);
    final paths = calloc<ffi.Pointer<ffi.Char>>(mediaPaths.length);
    var i = 0;
    try {
      for (final entry in mediaPaths.entries) {
        keys[i] = entry.key.toNativeUtf8().cast<ffi.Char>();
        paths[i] = entry.value.toNativeUtf8().cast<ffi.Char>();
        i++;
      }

      ffi.Pointer<ffi.Pointer<ffi.Char>> texKeys =
          ffi.nullptr;
      ffi.Pointer<cc_rgba_texture> texArray = ffi.nullptr;
      final texNativeKeys = <ffi.Pointer<ffi.Char>>[];
      if (textures.isNotEmpty) {
        texKeys = calloc<ffi.Pointer<ffi.Char>>(textures.length);
        texArray = calloc<cc_rgba_texture>(textures.length);
        var j = 0;
        textures.forEach((key, bytes) {
          texNativeKeys.add(key.toNativeUtf8().cast<ffi.Char>());
          texKeys[j] = texNativeKeys.last;
          final size = textureSizes[key];
          final buf = calloc<ffi.Uint8>(bytes.length);
          buf.asTypedList(bytes.length).setAll(0, bytes);
          final texRef = texArray[j];
          texRef.bytes = buf;
          texRef.width = size?.$1 ?? 0;
          texRef.height = size?.$2 ?? 0;
          j++;
        });
      }

      final outBuf = calloc<ffi.Pointer<ffi.Uint8>>();
      try {
        final code = _native.cc_render_frame_rgba(
          _engine,
          time.num,
          time.den,
          width,
          height,
          mediaPaths.length,
          keys,
          paths,
          textures.length,
          texKeys,
          texArray,
          outBuf,
        );
        if (code != 0) throw EngineException(code, _takeLastError());
        // Dimensions are implied: caller knows width*height*4.
        // setRange copies through memmove; Uint8List.fromList walks element by
        // element, which costs tens of milliseconds a frame in a JIT build.
        final length = width * height * 4;
        final view = outBuf.value.asTypedList(length);
        final bytes = Uint8List(length)..setRange(0, length, view);
        _native.cc_buffer_free(outBuf.value);
        return RawFrame(width, height, bytes);
      } finally {
        if (texArray != ffi.nullptr) {
          for (var k = 0; k < textures.length; k++) {
            calloc.free(texArray[k].bytes);
          }
        }
        if (texKeys != ffi.nullptr) {
          for (final p in texNativeKeys) {
            calloc.free(p);
          }
          calloc.free(texKeys);
        }
      }
    } finally {
      for (var k = 0; k < mediaPaths.length; k++) {
        calloc.free(keys[k]);
        calloc.free(paths[k]);
      }
      calloc.free(keys);
      calloc.free(paths);
    }
  }

  /// The v1 effect catalog as parsed JSON (FX gallery + inspector schema).
  List<Map<String, dynamic>> effectCatalog() {
    final out = calloc<ffi.Pointer<ffi.Char>>();
    try {
      final code = _native.cc_effect_catalog(_engine, out);
      if (code != 0) throw EngineException(code, _takeLastError());
      final list = jsonDecode(out.value.cast<Utf8>().toDartString()) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    } finally {
      calloc.free(out);
    }
  }

  // --- Sequence audio (M3) --------------------------------------------------

  /// Mixes [seconds] of the installed snapshot from [startSec] into
  /// interleaved stereo float32 at 48 kHz.
  Float32List mixAudio({
    required double startSec,
    required double seconds,
    required Map<String, String> mediaPaths,
  }) {
    final keys = calloc<ffi.Pointer<ffi.Char>>(mediaPaths.length);
    final paths = calloc<ffi.Pointer<ffi.Char>>(mediaPaths.length);
    final outSamples = calloc<ffi.Pointer<ffi.Float>>();
    final outFrames = calloc<ffi.Int32>();
    var i = 0;
    try {
      for (final entry in mediaPaths.entries) {
        keys[i] = entry.key.toNativeUtf8().cast<ffi.Char>();
        paths[i] = entry.value.toNativeUtf8().cast<ffi.Char>();
        i++;
      }
      final code = _native.cc_mix_audio(_engine, startSec, seconds,
          mediaPaths.length, keys, paths, outSamples, outFrames);
      if (code != 0) throw EngineException(code, _takeLastError());
      final count = outFrames.value * 2;
      final view = outSamples.value.asTypedList(count);
      final copy = Float32List(count)..setRange(0, count, view);
      _native.cc_buffer_free(outSamples.value.cast<ffi.Uint8>());
      return copy;
    } finally {
      for (var k = 0; k < i; k++) {
        calloc.free(keys[k]);
        calloc.free(paths[k]);
      }
      calloc.free(keys);
      calloc.free(paths);
      calloc.free(outSamples);
      calloc.free(outFrames);
    }
  }

  /// Integrated loudness and peaks of a mix window (AUD-12).
  LoudnessReport analyzeLoudness({
    required double startSec,
    required double seconds,
    required Map<String, String> mediaPaths,
  }) {
    final keys = calloc<ffi.Pointer<ffi.Char>>(mediaPaths.length);
    final paths = calloc<ffi.Pointer<ffi.Char>>(mediaPaths.length);
    final lufs = calloc<ffi.Double>();
    final peak = calloc<ffi.Double>();
    final truePeak = calloc<ffi.Double>();
    var i = 0;
    try {
      for (final entry in mediaPaths.entries) {
        keys[i] = entry.key.toNativeUtf8().cast<ffi.Char>();
        paths[i] = entry.value.toNativeUtf8().cast<ffi.Char>();
        i++;
      }
      final code = _native.cc_analyze_loudness(_engine, startSec, seconds,
          mediaPaths.length, keys, paths, lufs, peak, truePeak);
      if (code != 0) throw EngineException(code, _takeLastError());
      return LoudnessReport(
        lufs: lufs.value,
        peakDb: peak.value,
        truePeakDb: truePeak.value,
      );
    } finally {
      for (var k = 0; k < i; k++) {
        calloc.free(keys[k]);
        calloc.free(paths[k]);
      }
      calloc.free(keys);
      calloc.free(paths);
      calloc.free(lufs);
      calloc.free(peak);
      calloc.free(truePeak);
    }
  }

  /// Peak sample of an asset's audio over a source range (AUD-5 normalize).
  double scanAudioPeak(String path,
      {double sourceInSec = 0, required double seconds}) {
    final pathPtr = path.toNativeUtf8();
    final out = calloc<ffi.Double>();
    try {
      final code = _native.cc_scan_audio_peak(
          _engine, pathPtr.cast<ffi.Char>(), sourceInSec, seconds, out);
      if (code != 0) throw EngineException(code, _takeLastError());
      return out.value;
    } finally {
      calloc.free(pathPtr);
      calloc.free(out);
    }
  }

  /// Output devices, default first (AUD-14).
  List<String> audioOutputDevices() {
    final out = calloc<ffi.Pointer<ffi.Char>>();
    try {
      final code = _native.cc_audio_output_devices(_engine, out);
      if (code != 0) return const [];
      final joined = out.value.cast<Utf8>().toDartString();
      if (joined.isEmpty) return const [];
      return joined.split('\n');
    } finally {
      calloc.free(out);
    }
  }

  /// Realtime monitoring of the sequence mix; one per open project.
  SequenceAudioPlayer createSequencePlayer() =>
      SequenceAudioPlayer._(_native, _native.cc_seq_player_create());
}
