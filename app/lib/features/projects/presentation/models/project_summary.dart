import 'package:flutter/widgets.dart';

import '../../../../data/project.dart';

/// View model backing a card in the project browser. UI-only: the browser
/// screen renders whatever list it is handed.
@immutable
class ProjectSummary {
  const ProjectSummary({
    required this.name,
    required this.resolution,
    required this.fps,
    required this.duration,
    required this.lastOpened,
    required this.aspect,
    required this.thumbnail,
    required this.createdAt,
    this.path,
  });

  /// Builds a card from a project on disk. [modified] drives the "Opened …"
  /// line; [path] is what the browser reopens.
  factory ProjectSummary.fromDoc(ProjectDoc doc, {String? path, DateTime? modified}) {
    final s = doc.settings;
    final seconds = doc.sequenceDuration.seconds.round();
    return ProjectSummary(
      name: doc.name,
      resolution: '${s.width}×${s.height}',
      fps: s.fpsValue.round(),
      duration: '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
      lastOpened: 'Opened ${relativeTime(modified ?? doc.modifiedAt.toLocal())}',
      aspect: aspectLabel(s.width, s.height),
      thumbnail: thumbGradient(paletteFor(doc.id), _panel),
      createdAt: doc.createdAt.toLocal(),
      path: path,
    );
  }

  final String name;
  final String resolution;
  final int fps;
  final String duration;
  final String lastOpened;
  final String aspect;
  final Gradient thumbnail;
  final DateTime createdAt;

  /// Absolute path of the `.crazycut` file, when the card came from disk.
  final String? path;

  String get resolutionLabel => '$resolution · $fps';
}

/// Reduces a width/height to the nearest label the design uses.
String aspectLabel(int width, int height) {
  if (width == height) return '1:1';
  final ratio = width / height;
  if ((ratio - 16 / 9).abs() < 0.05) return '16:9';
  if ((ratio - 9 / 16).abs() < 0.05) return '9:16';
  if ((ratio - 4 / 5).abs() < 0.05) return '4:5';
  return '${width ~/ _gcd(width, height)}:${height ~/ _gcd(width, height)}';
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

String relativeTime(DateTime when) {
  final delta = DateTime.now().difference(when);
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  if (delta.inDays == 1) return 'yesterday';
  if (delta.inDays < 7) return '${delta.inDays} days ago';
  if (delta.inDays < 30) return '${(delta.inDays / 7).floor()} week(s) ago';
  return '${(delta.inDays / 30).floor()} month(s) ago';
}

/// Stable thumbnail tint per project, so a card keeps its colour between runs.
Color paletteFor(String seed) {
  const palette = [_blue, _magenta, _green, _gold, _teal, _violet, _grey];
  var hash = 0;
  for (final unit in seed.codeUnits) {
    hash = (hash * 31 + unit) & 0x7FFFFFFF;
  }
  return palette[hash % palette.length];
}

/// Linear gradient in the same direction the design uses for thumbnails.
Gradient thumbGradient(Color from, Color to) =>
    LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [from, to]);

const _panel = Color(0xFF1D1F23);

/// Thumbnail tints used until real poster frames land.
const _blue = Color(0xFF3B4F6B);
const _magenta = Color(0xFF6B3B5A);
const _green = Color(0xFF3B6B4F);
const _gold = Color(0xFF6B5A3B);
const _teal = Color(0xFF3B5F6B);
const _violet = Color(0xFF553B6B);
const _grey = Color(0xFF4A4D52);
