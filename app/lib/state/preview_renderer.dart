import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/models/rational.dart';

/// Chooses the sequence time that should be visible when an asynchronous
/// preview render is expected to finish. Parked/scrubbed frames stay exact;
/// playback leads by the measured render cost, bounded to avoid wild jumps.
Rt computePreviewRenderTime({
  required Rt playhead,
  required Rt rangeStart,
  required Rt rangeEnd,
  required Rt frameDuration,
  required bool playing,
  required double rate,
  required int renderMicros,
}) {
  if (!playing || rate == 0) return playhead;
  var lead = renderMicros;
  if (lead < frameDuration.micros) lead = frameDuration.micros;
  if (lead > 250000) lead = 250000;
  var target = playhead.plus(Rt.fromMicros(rate < 0 ? -lead : lead));
  if (target < rangeStart) target = rangeStart;
  if (target > rangeEnd) target = rangeEnd;
  return target;
}

/// Prevents an old seek, old document snapshot, or playback-state transition
/// from flashing on the monitor after a newer request superseded it.
///
/// Recency is decided by *dispatch order*, not by how close the rendered time
/// landed to the playhead. Proximity looked like the same thing and is not: a
/// clip that composites slower than the lead estimate can be bounded by
/// ([computePreviewRenderTime] clamps the lead to 250 ms) lands late by a
/// fixed margin on *every* frame, so a proximity window rejected all of them
/// and the monitor froze solid on exactly the heavy clips that most need
/// watching — a 4K source, a blur, a cold seek across a cut. A late frame is
/// worth showing; there is nothing better to put on screen.
///
/// [requestSeq] is the sequence number stamped when the request started and
/// [shownSeq] the one already on the monitor, so a request that overtakes an
/// older one still in flight — text rasterization can await before the
/// composite is even dispatched — can never be overwritten by it.
bool isPreviewFrameCurrent({
  required int requestRevision,
  required int currentRevision,
  required bool requestWasPlaying,
  required bool currentlyPlaying,
  required int requestSeq,
  required int shownSeq,
}) {
  // A different document, size or transport mode: these pixels answer a
  // question nobody is asking any more.
  if (requestRevision != currentRevision ||
      requestWasPlaying != currentlyPlaying) {
    return false;
  }
  return requestSeq > shownSeq;
}

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
