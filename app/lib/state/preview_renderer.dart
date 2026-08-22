import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/models/rational.dart';

/// One composited preview frame.
class PreviewFrame {
  const PreviewFrame({
    required this.time,
    required this.width,
    required this.height,
    required this.rgba,
  });

  final Rt time;
  final int width;
  final int height;
  final Uint8List rgba;
}

/// Renders composited preview frames on a dedicated isolate.
///
/// Compositing is a synchronous FFI call that can take tens of milliseconds;
/// running it on the UI isolate stalled every frame of the app, which is what
/// made scrubbing and playback stutter. The isolate owns its *own* engine
/// instance (engines are per-isolate singletons) and receives the document
/// snapshot separately, so it never touches state the UI isolate is mutating.
///
/// The engine's decoder cache is thread-local, so keeping one long-lived
/// isolate also keeps every source file open and positioned between frames —
/// sequential playback then decodes forward instead of re-seeking.
class PreviewRenderer {
  PreviewRenderer._(this._isolate, this._toIsolate, this._fromIsolate) {
    _sub = _fromIsolate.listen(_onMessage);
  }

  static Future<PreviewRenderer> spawn() async {
    final fromIsolate = ReceivePort();
    final ready = Completer<SendPort>();
    late final StreamSubscription<dynamic> handshake;
    final broadcast = fromIsolate.asBroadcastStream();
    handshake = broadcast.listen((dynamic message) {
      if (message is SendPort && !ready.isCompleted) {
        ready.complete(message);
        handshake.cancel();
      }
    });
    final isolate = await Isolate.spawn(
      _isolateMain,
      fromIsolate.sendPort,
      debugName: 'crazycut-preview',
      errorsAreFatal: false,
    );
    final toIsolate = await ready.future;
    return PreviewRenderer._(isolate, toIsolate, broadcast);
  }

  final Isolate _isolate;
  final SendPort _toIsolate;
  final Stream<dynamic> _fromIsolate;
  late final StreamSubscription<dynamic> _sub;

  final Map<int, Completer<PreviewFrame>> _pending = {};
  int _nextId = 1;
  bool _closed = false;

  /// How many renders may be outstanding at once. Two keeps the isolate busy
  /// while the UI paints the previous frame without building a long queue of
  /// stale positions.
  static const int maxInFlight = 2;

  int get inFlight => _pending.length;
  bool get idle => _pending.isEmpty;

  /// Installs the document the isolate renders from. Must be called before the
  /// first render and after every committed edit.
  void setSnapshot(String projectJson) {
    if (_closed) return;
    _toIsolate.send({'type': 'snapshot', 'json': projectJson});
  }

  Future<PreviewFrame> render({
    required Rt time,
    required int width,
    required int height,
    required Map<String, String> mediaPaths,
    Map<String, Uint8List> textures = const {},
    Map<String, (int, int)> textureSizes = const {},
  }) {
    if (_closed) return Future.error(StateError('renderer closed'));
    final id = _nextId++;
    final completer = Completer<PreviewFrame>();
    _pending[id] = completer;
    _toIsolate.send({
      'type': 'render',
      'id': id,
      'num': time.num,
      'den': time.den,
      'width': width,
      'height': height,
      'mediaPaths': mediaPaths,
      // Transferable buffers move without a copy.
      'textures': textures.map(
        (k, v) => MapEntry(k, TransferableTypedData.fromList([v])),
      ),
      'textureSizes':
          textureSizes.map((k, v) => MapEntry(k, <int>[v.$1, v.$2])),
    });
    return completer.future;
  }

  void _onMessage(dynamic message) {
    if (message is! Map) return;
    final id = message['id'] as int?;
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (message['type'] == 'frame') {
      completer.complete(PreviewFrame(
        time: Rt(message['num'] as int, message['den'] as int),
        width: message['width'] as int,
        height: message['height'] as int,
        rgba: (message['rgba'] as TransferableTypedData)
            .materialize()
            .asUint8List(),
      ));
    } else {
      completer.completeError(
          EngineException(-1, (message['error'] as String?) ?? 'render failed'));
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      completer.completeError(StateError('renderer closed'));
    }
    _pending.clear();
    _toIsolate.send({'type': 'shutdown'});
    await _sub.cancel();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  // --- Isolate side ---------------------------------------------------------

  static void _isolateMain(SendPort toMain) {
    final port = ReceivePort();
    toMain.send(port.sendPort);
    final engine = CrazyCutEngine.instance;

    port.listen((dynamic message) {
      if (message is! Map) return;
      switch (message['type']) {
        case 'snapshot':
          try {
            engine.setProjectSnapshot(message['json'] as String);
          } catch (_) {
            // A bad snapshot surfaces on the next render as an error frame.
          }
        case 'render':
          final id = message['id'] as int;
          try {
            final textures = <String, Uint8List>{};
            (message['textures'] as Map).forEach((k, v) {
              textures[k as String] =
                  (v as TransferableTypedData).materialize().asUint8List();
            });
            final sizes = <String, (int, int)>{};
            (message['textureSizes'] as Map).forEach((k, v) {
              final pair = (v as List).cast<int>();
              sizes[k as String] = (pair[0], pair[1]);
            });
            final frame = engine.renderFrameRgba(
              time: Rt(message['num'] as int, message['den'] as int),
              width: message['width'] as int,
              height: message['height'] as int,
              mediaPaths: (message['mediaPaths'] as Map).cast<String, String>(),
              textures: textures,
              textureSizes: sizes,
            );
            toMain.send({
              'type': 'frame',
              'id': id,
              'num': message['num'],
              'den': message['den'],
              'width': frame.width,
              'height': frame.height,
              'rgba': TransferableTypedData.fromList([frame.rgba]),
            });
          } catch (e) {
            toMain.send({'type': 'error', 'id': id, 'error': '$e'});
          }
        case 'shutdown':
          engine.close();
          port.close();
      }
    });
  }
}
