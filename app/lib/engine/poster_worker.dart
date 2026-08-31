import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/core/math/rational.dart';

part 'poster_frame.dart';

/// Off-thread poster-frame rendering (project browser cards).
///
/// Compositing a frame is the same synchronous FFI call the live monitor
/// uses; running it on the UI isolate while the browser lists many projects
/// would stall the grid, so this mirrors [MediaWorker]'s long-lived isolate.
class PosterWorker {
  PosterWorker._();

  static final PosterWorker instance = PosterWorker._();

  SendPort? _requests;
  Completer<void>? _starting;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 0;

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
      await Isolate.spawn(_entryPoint, responses.sendPort, debugName: 'crazycut-poster');
    } on Object catch (e) {
      unavailable = true;
      if (!starting.isCompleted) starting.completeError(e);
    }
    return starting.future;
  }

  /// Renders one frame of [projectJson] at [time] into [width]x[height], or
  /// null when the worker isolate could not start or the render failed.
  Future<PosterFrame?> render({
    required String projectJson,
    required Map<String, String> mediaPaths,
    required Rt time,
    required int width,
    required int height,
  }) async {
    if (unavailable) return null;
    try {
      await _ensureStarted();
      final port = _requests;
      if (port == null) return null;
      final id = _nextId++;
      final completer = Completer<Object?>();
      _pending[id] = completer;
      port.send({
        'id': id,
        'op': 'poster',
        'projectJson': projectJson,
        'mediaPaths': mediaPaths,
        'num': time.num,
        'den': time.den,
        'width': width,
        'height': height,
      });
      final result = await completer.future;
      if (result == null) return null;
      final map = result as Map<Object?, Object?>;
      return PosterFrame(
        width: map['width'] as int,
        height: map['height'] as int,
        rgba: (map['rgba'] as TransferableTypedData).materialize().asUint8List(),
      );
    } on Object {
      return null;
    }
  }

  static void _entryPoint(SendPort responses) {
    final requests = ReceivePort();
    responses.send(requests.sendPort);
    final engine = CrazyCutEngine.instance;
    requests.listen((message) {
      final map = message as Map<String, Object?>;
      final id = map['id'] as int;
      try {
        switch (map['op'] as String) {
          case 'poster':
            engine.setProjectSnapshot(map['projectJson'] as String);
            final frame = engine.renderFrameRgba(
              time: Rt(map['num'] as int, map['den'] as int),
              width: map['width'] as int,
              height: map['height'] as int,
              mediaPaths: (map['mediaPaths'] as Map).cast<String, String>(),
            );
            responses.send({
              'id': id,
              'result': {
                'width': frame.width,
                'height': frame.height,
                'rgba': TransferableTypedData.fromList([frame.rgba]),
              },
            });
          default:
            responses.send({'id': id, 'error': 'unknown op'});
        }
      } on Object catch (e) {
        responses.send({'id': id, 'error': e.toString()});
      }
    });
  }
}
