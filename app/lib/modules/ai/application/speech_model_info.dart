part of 'speech_model.dart';

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
