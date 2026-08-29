import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crazycut_app/engine/engine.dart';

/// Off-thread media decoding.
///
/// Filmstrip tiles and waveforms would otherwise run ffmpeg seeks on the UI
/// isolate and drop frames while scrolling the timeline (TIM-22). One
/// long-lived isolate opens its own copy of the engine and answers requests in
/// order; callers get plain futures.
class MediaWorker {
  MediaWorker._();

  static final MediaWorker instance = MediaWorker._();

  SendPort? _requests;
  Completer<void>? _starting;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 0;

  /// Set when the isolate cannot open the engine, so callers stop asking.
  bool unavailable = false;

  Future<void> _ensureStarted() async {
    if (_requests != null) return;
    if (_starting != null) return _starting!.future;
    final starting = _starting = Completer<void>();
    final responses = ReceivePort();
    responses.listen((message) {
      if (message is SendPort) {
        _requests = message;
        if (!starting.isCompleted) starting.complete();
        return;
      }
      final map = message as Map<String, Object?>;
      final completer = _pending.remove(map['id'] as int);
      if (completer == null) return;
      final error = map['error'];
      if (error != null) {
        completer.completeError(StateError(error.toString()));
      } else {
        completer.complete(map['result']);
      }
    });
    try {
      await Isolate.spawn(
        _entryPoint,
        responses.sendPort,
        debugName: 'crazycut-media',
      );
    } on Object catch (e) {
      unavailable = true;
      if (!starting.isCompleted) starting.completeError(e);
    }
    return starting.future;
  }

  Future<Object?> _send(String op, Map<String, Object?> args) async {
    await _ensureStarted();
    final port = _requests;
    if (port == null) throw StateError('media worker unavailable');
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send({'id': id, 'op': op, ...args});
    return completer.future;
  }

  Future<Uint8List?> thumbnail(
    String path, {
    double seconds = 0,
    int width = 320,
  }) async {
    if (unavailable) return null;
    try {
      final result = await _send('thumb', {
        'path': path,
        'seconds': seconds,
        'width': width,
      });
      return result as Uint8List?;
    } on Object {
      return null;
    }
  }

  Future<ProbeResult?> probe(String source) async {
    if (unavailable) return null;
    final result = await _send('probe', {'path': source});
    if (result is! Map) return null;
    return ProbeResult.fromJson(Map<String, dynamic>.from(result));
  }

  Future<List<double>?> waveform(String path, {int peaksPerSecond = 20}) async {
    if (unavailable) return null;
    try {
      final result = await _send('waveform', {
        'path': path,
        'peaksPerSecond': peaksPerSecond,
      });
      return (result as List<Object?>?)?.cast<double>();
    } on Object {
      return null;
    }
  }

  static void _entryPoint(SendPort responses) {
    final requests = ReceivePort();
    responses.send(requests.sendPort);
    requests.listen((message) {
      final map = message as Map<String, Object?>;
      final id = map['id'] as int;
      try {
        switch (map['op'] as String) {
          case 'probe':
            final probe = CrazyCutEngine.instance.probeFile(
              map['path'] as String,
            );
            responses.send({'id': id, 'result': probe.raw});
          case 'thumb':
            final bytes = CrazyCutEngine.instance.extractThumbnail(
              map['path'] as String,
              seconds: map['seconds'] as double,
              width: map['width'] as int,
            );
            responses.send({'id': id, 'result': bytes});
          case 'waveform':
            final result = CrazyCutEngine.instance.extractWaveform(
              map['path'] as String,
              peaksPerSecond: map['peaksPerSecond'] as int,
            );
            final peaks =
                result.peaks
                    .map((p) => (p as num).toDouble().abs().clamp(0.0, 1.0))
                    .toList();
            responses.send({'id': id, 'result': peaks});
          default:
            responses.send({'id': id, 'error': 'unknown op'});
        }
      } on Object catch (e) {
        responses.send({'id': id, 'error': e.toString()});
      }
    });
  }
}
