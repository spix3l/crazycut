part of 'editor_controller.dart';

/// UIX 3.2 playback quality dropdown, reflecting engine tiers.
enum PreviewQuality {
  auto,
  full,
  half,
  proxy;

  String get label => switch (this) {
    PreviewQuality.auto => 'Auto',
    PreviewQuality.full => 'Full',
    PreviewQuality.half => 'Half',
    PreviewQuality.proxy => 'Proxy',
  };
}
