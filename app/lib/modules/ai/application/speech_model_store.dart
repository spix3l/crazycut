part of 'speech_model.dart';

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
