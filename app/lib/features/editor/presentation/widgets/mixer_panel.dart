import 'dart:math' as math;

import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/state/audio_edits.dart';
import 'package:crazycut_app/state/editor_controller.dart';

/// The mixer (AUD-10): one strip per audio-bearing track plus the master.
///
/// Faders and pans write straight through the command stack, so a mix move is
/// as undoable as a trim. Meters read the peaks the audio device last played,
/// which is why they only move while monitoring runs.
class MixerPanel extends StatelessWidget {
  const MixerPanel({super.key, required this.controller, this.onClose});

  final EditorController controller;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    // Video tracks appear too: a linked A/V clip's sound rides its own track.
    final tracks = [
      ...c.doc.audioTracks,
      ...c.doc.videoTracks.where((t) => _hasAudioClips(c.doc, t)),
    ];

    return Container(
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: Border(left: BorderSide(color: CcColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 36,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const CcIcon(LucideIcons.sliders, size: 14),
                  const SizedBox(width: 8),
                  Text('Mixer', style: CcType.bodyStrong),
                  const Spacer(),
                  if (onClose != null)
                    CcTappable(
                      onTap: onClose,
                      child: const CcIcon(LucideIcons.x, size: 13),
                    ),
                ],
              ),
            ),
          ),
          const CcDivider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final track in tracks) ...[
                    _TrackStrip(controller: c, track: track),
                    const SizedBox(width: 10),
                  ],
                  _MasterStrip(controller: c),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static bool _hasAudioClips(ProjectDoc doc, Track track) {
    for (final clip in doc.clipsOn(track.id)) {
      final asset = doc.assetById(clip.mediaId);
      if (asset != null && asset.hasAudio) return true;
    }
    return false;
  }
}

class _TrackStrip extends StatelessWidget {
  const _TrackStrip({required this.controller, required this.track});

  final EditorController controller;
  final Track track;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final anySolo = c.doc.tracks.any((t) => t.solo);
    final audible = anySolo ? track.solo : !track.mute;
    return _Metered(
      controller: c,
      builder: (level) => _Strip(
        title: track.name,
        gainDb: AudioEdits.linearToDb(track.gain),
        maxDb: 6,
        onGainDb: (db) => c.setTrackGainDb(track.id, db),
        pan: track.pan,
        onPan: (v) => c.setTrackPan(track.id, v),
        // Per-track metering needs a per-track mix; v1 meters the master and
        // shows track strips as active/inactive instead of guessing a level.
        level: audible && c.playing ? level : (0, 0),
        dimmed: !audible,
        buttons: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _ToggleChip(
              label: 'M',
              on: track.mute,
              onTap: () => c.setTrackFlags(track.id, mute: !track.mute),
            ),
            const SizedBox(width: 6),
            _ToggleChip(
              label: 'S',
              on: track.solo,
              onTap: () => c.setTrackFlags(track.id, solo: !track.solo),
            ),
          ],
        ),
      ),
    );
  }
}

class _MasterStrip extends StatelessWidget {
  const _MasterStrip({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final master = c.doc.settings.master;
    return _Metered(
      controller: c,
      builder: (level) => _Strip(
        title: 'Master',
        gainDb: AudioEdits.linearToDb(master.gain),
        maxDb: 6,
        onGainDb: c.setMasterGainDb,
        pan: null,
        onPan: null,
        level: c.playing ? level : (0, 0),
        dimmed: false,
        accent: true,
        buttons: CcTooltip(
          message: 'Safety brickwall at ${master.ceilingDb.toStringAsFixed(0)} dBFS',
          child: _ToggleChip(
            label: 'LIM',
            on: master.limiter,
            width: 40,
            onTap: () => c.setMasterLimiter(!master.limiter),
          ),
        ),
      ),
    );
  }
}

/// Rebuilds one strip when the meter moves. Levels update every transport
/// tick; the rest of the mixer does not have to.
class _Metered extends StatelessWidget {
  const _Metered({required this.controller, required this.builder});

  final EditorController controller;
  final Widget Function((double, double) level) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<(double, double)>(
      valueListenable: controller.audioLevelsNotifier,
      builder: (context, level, _) => builder(level),
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({
    required this.title,
    required this.gainDb,
    required this.maxDb,
    required this.onGainDb,
    required this.pan,
    required this.onPan,
    required this.level,
    required this.buttons,
    this.dimmed = false,
    this.accent = false,
  });

  final String title;
  final double gainDb;
  final double maxDb;
  final ValueChanged<double> onGainDb;
  final double? pan;
  final ValueChanged<double>? onPan;
  final (double, double) level;
  final Widget buttons;
  final bool dimmed;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    const minDb = AudioEdits.kSilenceDb;
    final position = ((gainDb - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);
    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: Container(
        width: 84,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: CcColors.elevated,
          borderRadius: CcRadius.brSm,
          border: accent
              ? Border.all(color: CcColors.accent.withValues(alpha: 0.5))
              : null,
        ),
        child: Column(
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CcType.style(size: 11, weight: CcType.semibold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  RotatedBox(
                    quarterTurns: 3,
                    child: SizedBox(
                      width: 120,
                      child: CcSlider(
                        value: position,
                        onChanged: (v) => onGainDb(minDb + v * (maxDb - minDb)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _Meter(level: level),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              gainDb <= minDb ? '−∞' : '${gainDb >= 0 ? '+' : ''}${gainDb.toStringAsFixed(1)}',
              style: CcType.style(size: 10, color: CcColors.textSecondary),
            ),
            if (pan != null) ...[
              const SizedBox(height: 6),
              CcSlider(
                value: (pan! + 1) / 2,
                onChanged: onPan == null ? null : (v) => onPan!(v * 2 - 1),
              ),
              Text(
                pan == 0
                    ? 'C'
                    : '${pan! < 0 ? 'L' : 'R'}${(pan!.abs() * 100).round()}',
                style: CcType.style(size: 10, color: CcColors.textTertiary),
              ),
            ],
            const SizedBox(height: 8),
            buttons,
          ],
        ),
      ),
    );
  }
}

/// Stereo peak meter with peak-hold (AUD-10).
class _Meter extends StatefulWidget {
  const _Meter({required this.level});

  final (double, double) level;

  @override
  State<_Meter> createState() => _MeterState();
}

class _MeterState extends State<_Meter> {
  double _holdL = 0;
  double _holdR = 0;

  @override
  void didUpdateWidget(_Meter old) {
    super.didUpdateWidget(old);
    // Peaks fall back slowly so a transient stays readable.
    _holdL = math.max(widget.level.$1, _holdL - 0.02);
    _holdR = math.max(widget.level.$2, _holdR - 0.02);
    if (widget.level.$1 == 0 && widget.level.$2 == 0) {
      _holdL = math.max(0, _holdL - 0.05);
      _holdR = math.max(0, _holdR - 0.05);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _MeterBar(value: widget.level.$1, hold: _holdL),
          _MeterBar(value: widget.level.$2, hold: _holdR),
        ],
      ),
    );
  }
}

class _MeterBar extends StatelessWidget {
  const _MeterBar({required this.value, required this.hold});

  final double value;
  final double hold;

  /// Meters are read in dB: a linear bar spends most of its length on levels
  /// nobody cares about.
  static double _scale(double amplitude) {
    if (amplitude <= 0) return 0;
    final db = 20 * (math.log(amplitude) / math.ln10);
    return ((db + 60) / 60).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final fill = _scale(value);
    final holdAt = _scale(hold);
    return SizedBox(
      width: 6,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final h = constraints.maxHeight;
          return Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: CcColors.bg,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: h * fill,
                child: Container(
                  decoration: BoxDecoration(
                    color: value > 0.95
                        ? CcColors.error
                        : value > 0.7
                            ? CcColors.warning
                            : CcColors.success,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
              if (holdAt > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: (h * holdAt).clamp(0.0, h - 1),
                  height: 1,
                  child: const ColoredBox(color: CcColors.textSecondary),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  const _ToggleChip({
    required this.label,
    required this.on,
    required this.onTap,
    this.width = 22,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Container(
        width: width,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? CcColors.accent : CcColors.elevated2,
          borderRadius: BorderRadius.circular(CcRadius.sm),
        ),
        child: Text(
          label,
          style: CcType.style(
            size: 10,
            weight: CcType.semibold,
            color: on ? CcColors.onAccent : CcColors.textTertiary,
          ),
        ),
      ),
    );
  }
}
