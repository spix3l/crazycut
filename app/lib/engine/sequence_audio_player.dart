part of 'engine.dart';

/// Thin owner of a native `cc_seq_player`.
class SequenceAudioPlayer {
  SequenceAudioPlayer._(this._native, this._handle);

  final CrazyCutNativeBindings _native;
  ffi.Pointer<cc_seq_player> _handle;

  bool get _alive => _handle != ffi.nullptr;

  /// Installs the document and asset paths the mixer reads.
  void setDocument(String projectJson, Map<String, String> mediaPaths) {
    if (!_alive) return;
    final jsonPtr = projectJson.toNativeUtf8();
    final keys = calloc<ffi.Pointer<ffi.Char>>(mediaPaths.length);
    final paths = calloc<ffi.Pointer<ffi.Char>>(mediaPaths.length);
    var i = 0;
    try {
      for (final entry in mediaPaths.entries) {
        keys[i] = entry.key.toNativeUtf8().cast<ffi.Char>();
        paths[i] = entry.value.toNativeUtf8().cast<ffi.Char>();
        i++;
      }
      _native.cc_seq_player_set_document(
          _handle, jsonPtr.cast<ffi.Char>(), mediaPaths.length, keys, paths);
    } finally {
      for (var k = 0; k < i; k++) {
        calloc.free(keys[k]);
        calloc.free(paths[k]);
      }
      calloc.free(keys);
      calloc.free(paths);
      calloc.free(jsonPtr);
    }
  }

  void start(double positionSec) {
    if (_alive) _native.cc_seq_player_start(_handle, positionSec);
  }

  void stop() {
    if (_alive) _native.cc_seq_player_stop(_handle);
  }

  void seek(double positionSec) {
    if (_alive) _native.cc_seq_player_seek(_handle, positionSec);
  }

  double get position =>
      _alive ? _native.cc_seq_player_position(_handle) : 0;

  bool get running =>
      _alive && _native.cc_seq_player_is_running(_handle) != 0;

  set rate(double value) {
    if (_alive) _native.cc_seq_player_set_rate(_handle, value);
  }

  /// Peak levels of the last buffer sent to the device, for the meters.
  (double, double) get levels {
    if (!_alive) return (0, 0);
    final l = calloc<ffi.Float>();
    final r = calloc<ffi.Float>();
    try {
      _native.cc_seq_player_levels(_handle, l, r);
      return (l.value, r.value);
    } finally {
      calloc.free(l);
      calloc.free(r);
    }
  }

  set outputDevice(String name) {
    if (!_alive) return;
    final ptr = name.toNativeUtf8();
    try {
      _native.cc_seq_player_set_output_device(_handle, ptr.cast<ffi.Char>());
    } finally {
      calloc.free(ptr);
    }
  }

  void dispose() {
    if (!_alive) return;
    _native.cc_seq_player_destroy(_handle);
    _handle = ffi.nullptr;
  }
}
