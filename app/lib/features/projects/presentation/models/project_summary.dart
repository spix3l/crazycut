import 'package:flutter/widgets.dart';

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
  });

  final String name;
  final String resolution;
  final int fps;
  final String duration;
  final String lastOpened;
  final String aspect;
  final Gradient thumbnail;

  String get resolutionLabel => '$resolution · $fps';
}

/// Linear gradient in the same direction the design uses for thumbnails.
Gradient thumbGradient(Color from, Color to) => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [from, to],
    );

const _panel = Color(0xFF1D1F23);

/// Placeholder content for the populated browser screen.
const _blue = Color(0xFF3B4F6B);
const _magenta = Color(0xFF6B3B5A);
const _green = Color(0xFF3B6B4F);
const _gold = Color(0xFF6B5A3B);
const _teal = Color(0xFF3B5F6B);
const _violet = Color(0xFF553B6B);
const _grey = Color(0xFF4A4D52);

final sampleProjects = <ProjectSummary>[
  ProjectSummary(
    name: 'Beauty Routine Ep. 12',
    resolution: '1920×1080',
    fps: 30,
    duration: '12:34',
    lastOpened: 'Opened 2h ago',
    aspect: '16:9',
    thumbnail: thumbGradient(_blue, _panel),
  ),
  ProjectSummary(
    name: 'Get Ready With Me',
    resolution: '1080×1920',
    fps: 30,
    duration: '0:48',
    lastOpened: 'Opened yesterday',
    aspect: '9:16',
    thumbnail: thumbGradient(_magenta, _panel),
  ),
  ProjectSummary(
    name: 'Studio Tour Vertical',
    resolution: '1080×1920',
    fps: 60,
    duration: '1:22',
    lastOpened: 'Opened 2 days ago',
    aspect: '9:16',
    thumbnail: thumbGradient(_green, _panel),
  ),
  ProjectSummary(
    name: 'Product Demo — v3',
    resolution: '1920×1080',
    fps: 30,
    duration: '3:05',
    lastOpened: 'Opened 3 days ago',
    aspect: '16:9',
    thumbnail: thumbGradient(_gold, _panel),
  ),
  ProjectSummary(
    name: 'Shorts Compilation',
    resolution: '1080×1080',
    fps: 30,
    duration: '0:31',
    lastOpened: 'Opened 5 days ago',
    aspect: '1:1',
    thumbnail: thumbGradient(_teal, _panel),
  ),
  ProjectSummary(
    name: 'Indie Founder Q&A',
    resolution: '1920×1080',
    fps: 24,
    duration: '18:42',
    lastOpened: 'Opened 1 week ago',
    aspect: '16:9',
    thumbnail: thumbGradient(_violet, _panel),
  ),
  ProjectSummary(
    name: 'Untitled Project',
    resolution: '1920×1080',
    fps: 30,
    duration: '0:00',
    lastOpened: 'Opened 2 weeks ago',
    aspect: '16:9',
    thumbnail: thumbGradient(_grey, _panel),
  ),
  ProjectSummary(
    name: 'Trip Recap Draft',
    resolution: '1080×1920',
    fps: 30,
    duration: '2:14',
    lastOpened: 'Opened 3 weeks ago',
    aspect: '9:16',
    thumbnail: thumbGradient(_teal, _panel),
  ),
];
