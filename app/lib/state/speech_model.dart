/// The local speech model: where it lives, and getting it there (AI-19).
///
/// CrazyCut ships without a model. The first time transcription is asked for,
/// the user is told the size and asked; declining leaves the feature
/// unavailable with a clear message rather than a crash, and nothing is ever
/// downloaded silently.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:crazycut_app/data/media_cache.dart';

class SpeechModelInfo {
  const SpeechModelInfo({
    required this.id,
    required this.fileName,
    required this.url,
    required this.approxBytes,
    required this.label,
    required this.blurb,
  });

  final String id;
  final String fileName;
  final String url;
  final int approxBytes;
  final String label;
  final String blurb;

  String get sizeLabel => '${(approxBytes / (1024 * 1024)).round()} MB';
}

/// Two sizes: the default is a reasonable accuracy/speed trade on a laptop,
/// with a smaller one for machines where that is too slow.
const kSpeechModels = <SpeechModelInfo>[
  SpeechModelInfo(
    id: 'base.en',
    fileName: 'ggml-base.en.bin',
    url:
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin',
    approxBytes: 148 * 1024 * 1024,
    label: 'Base (English)',
    blurb: 'The default. Good accuracy, roughly 5–10× faster than realtime.',
  ),
  SpeechModelInfo(
    id: 'tiny.en',
    fileName: 'ggml-tiny.en.bin',
    url:
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin',
    approxBytes: 75 * 1024 * 1024,
    label: 'Tiny (English)',
    blurb: 'Faster and smaller, noticeably less accurate on difficult audio.',
  ),
];

SpeechModelInfo speechModelById(String id) =>
    kSpeechModels.firstWhere((m) => m.id == id, orElse: () => kSpeechModels.first);

class SpeechModelStore extends ChangeNotifier {
  SpeechModelStore({http.Client? client}) : _client = client ?? http.Client();

  static final SpeechModelStore instance = SpeechModelStore();

  final http.Client _client;

  double? _progress;
  String? _error;
  bool _cancelled = false;

  /// Download progress in [0,1], or null when nothing is downloading.
  double? get progress => _progress;
  String? get error => _error;
  bool get isDownloading => _progress != null;

  Future<Directory> _dir() async {
    final base = await MediaCache.instance.dir();
    final dir = Directory('${base.path}${Platform.pathSeparator}models');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<File> fileFor(SpeechModelInfo model) async =>
      File('${(await _dir()).path}${Platform.pathSeparator}${model.fileName}');

  Future<bool> isInstalled(SpeechModelInfo model) async =>
      (await fileFor(model)).existsSync();

  /// The path to use for transcription, or null when the model is absent.
  Future<String?> pathIfInstalled(SpeechModelInfo model) async {
    final file = await fileFor(model);
    return file.existsSync() ? file.path : null;
  }

  void cancel() {
    _cancelled = true;
  }

  /// Downloads [model], streaming to a temporary file and renaming into place
  /// only on success — a cancelled or failed download never leaves something
  /// that looks like a usable model.
  Future<bool> download(SpeechModelInfo model) async {
    if (isDownloading) return false;
    _cancelled = false;
    _error = null;
    _progress = 0;
    notifyListeners();

    final target = await fileFor(model);
    final partial = File('${target.path}.part');
    IOSink? sink;

    try {
      final request = http.Request('GET', Uri.parse(model.url));
      final response = await _client.send(request);
      if (response.statusCode != 200) {
        throw HttpException(
          'the download server answered ${response.statusCode}',
        );
      }

      final total = response.contentLength ?? model.approxBytes;
      var received = 0;
      sink = partial.openWrite();

      await for (final chunk in response.stream) {
        if (_cancelled) throw const _CancelledDownload();
        sink.add(chunk);
        received += chunk.length;
        final next = total > 0 ? (received / total).clamp(0.0, 1.0) : null;
        if (next != null && ((next - (_progress ?? 0)) > 0.005 || next >= 1)) {
          _progress = next;
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (target.existsSync()) await target.delete();
      await partial.rename(target.path);
      _progress = null;
      notifyListeners();
      return true;
    } on Object catch (e) {
      try {
        await sink?.close();
      } on Object {
        // Already closing down.
      }
      if (partial.existsSync()) {
        try {
          await partial.delete();
        } on Object {
          // Best effort; a leftover .part is never mistaken for a model.
        }
      }
      _progress = null;
      _error = e is _CancelledDownload
          ? null
          : 'The speech model could not be downloaded: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> remove(SpeechModelInfo model) async {
    final file = await fileFor(model);
    if (file.existsSync()) await file.delete();
    notifyListeners();
  }
}

class _CancelledDownload implements Exception {
  const _CancelledDownload();
  @override
  String toString() => 'cancelled';
}
