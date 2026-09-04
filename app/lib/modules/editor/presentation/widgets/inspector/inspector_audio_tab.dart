import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/application/audio_edits.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';

import 'inspector_rows.dart';

/// Per-clip audio: level, balance, fades and the detach/link controls
/// (AUD-1/2/3/5/6).
class ClipAudioTab extends StatelessWidget {
  const ClipAudioTab({super.key, required this.controller, required this.clip});

  final EditorController controller;
  final Clip clip;

  static const _curves = ['linear', 'exponential', 'scurve'];
  static const _curveLabels = ['Linear', 'Expo', 'S-curve'];

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final fps = c.fps;
    final asset = c.doc.assetById(clip.mediaId);
    final silent = asset == null || !asset.hasAudio;
    final drift = c.linkedDrift(clip.id);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (silent)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: _Notice(
                icon: LucideIcons.volumeX,
                message: 'This clip has no audio stream.',
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: CcSectionHeader('LEVELS'),
          ),
          SliderRow(
            label: 'Volume',
            // The fader is dB-linear: −48 (silence) to +12.
            value:
                (_db(clip.volume) - AudioEdits.kSilenceDb) /
                (12.0 - AudioEdits.kSilenceDb),
            display: _dbLabel(clip.volume),
            onChanged:
                silent
                    ? null
                    : (v) => c.setClipVolumeDb(
                      clip.id,
                      AudioEdits.kSilenceDb +
                          v * (12.0 - AudioEdits.kSilenceDb),
                    ),
            editText: _dbEditText(clip.volume),
            onCommitText:
                silent
                    ? null
                    : (raw) {
                      final db = parseCcDb(raw);
                      if (db == null) return;
                      final clamped =
                          db.isInfinite
                              ? AudioEdits.kSilenceDb
                              : db.clamp(AudioEdits.kSilenceDb, 12.0);
                      c.setClipVolumeDb(clip.id, clamped);
                    },
          ),
          SliderRow(
            label: 'Pan',
            value: (clip.pan + 1) / 2,
            display: _panLabel(clip.pan),
            onChanged: silent ? null : (v) => c.setClipPan(clip.id, v * 2 - 1),
            editText: _panEditText(clip.pan),
            onCommitText:
                silent
                    ? null
                    : (raw) {
                      final pan = parseCcPan(raw);
                      if (pan == null) return;
                      c.setClipPan(clip.id, pan);
                    },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
            child: Row(
              children: [
                CcCheckbox(
                  checked: clip.mute,
                  onTap: () => c.setClipMuted(clip.id, !clip.mute),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text('Mute clip', style: CcType.small)),
                CcTooltip(
                  message: 'Scan peaks and set gain for −1 dBFS',
                  child: CcButton(
                    label: 'Normalize',
                    kind: CcButtonKind.secondary,
                    height: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    onPressed: silent ? null : () => c.normalizeClip(clip.id),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: CcSectionHeader('FADES'),
          ),
          TimecodeRow(
            label: 'Fade in',
            value: clip.fadeIn.duration,
            fps: fps,
            onSubmitted:
                (value) =>
                    c.setClipFade(clip.id, fadeIn: true, duration: value),
          ),
          _CurveRow(
            label: 'In curve',
            selected: _curves.indexOf(clip.fadeIn.curve).clamp(0, 2),
            labels: _curveLabels,
            onChanged:
                (i) => c.setFadeCurve(clip.id, fadeIn: true, curve: _curves[i]),
          ),
          TimecodeRow(
            label: 'Fade out',
            value: clip.fadeOut.duration,
            fps: fps,
            onSubmitted:
                (value) =>
                    c.setClipFade(clip.id, fadeIn: false, duration: value),
          ),
          _CurveRow(
            label: 'Out curve',
            selected: _curves.indexOf(clip.fadeOut.curve).clamp(0, 2),
            labels: _curveLabels,
            onChanged:
                (i) =>
                    c.setFadeCurve(clip.id, fadeIn: false, curve: _curves[i]),
          ),
          const SizedBox(height: 10),
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: CcSectionHeader('LINKED AUDIO'),
          ),
          if (drift != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Row(
                children: [
                  const CcBadge('Out of sync'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${Rt.toTimecode(drift < Rt.zero() ? Rt.zero().minus(drift) : drift, fps)} apart',
                      style: CcType.style(
                        size: 11,
                        color: CcColors.textTertiary,
                      ),
                    ),
                  ),
                  CcButton(
                    label: 'Sync',
                    kind: CcButtonKind.secondary,
                    height: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    onPressed: () => c.syncLinked(clip.id),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Row(
              children: [
                if (c.canDetachAudio(clip.id))
                  CcButton(
                    label: 'Detach audio',
                    icon: LucideIcons.unlink,
                    kind: CcButtonKind.secondary,
                    height: 28,
                    onPressed: () => c.detachAudio(clip.id),
                  )
                else if (clip.linkedGroup != null)
                  CcButton(
                    label: 'Relink',
                    icon: LucideIcons.link,
                    kind: CcButtonKind.secondary,
                    height: 28,
                    onPressed: () => c.relinkAudio(clip.id),
                  )
                else
                  Expanded(
                    child: Text(
                      silent
                          ? 'Nothing to detach.'
                          : 'Audio is on its own track.',
                      style: CcType.style(
                        size: 11,
                        color: CcColors.textTertiary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (c.lastAudioNotice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: _Notice(
                icon: LucideIcons.triangleAlert,
                message: c.lastAudioNotice!,
                onDismiss: c.clearAudioNotice,
              ),
            ),
        ],
      ),
    );
  }

  static double _db(double linear) => AudioEdits.linearToDb(linear);

  static String _dbLabel(double linear) {
    final db = AudioEdits.linearToDb(linear);
    if (db <= AudioEdits.kSilenceDb) return '−∞';
    return '${db >= 0 ? '+' : ''}${db.toStringAsFixed(1)}';
  }

  static String _panLabel(double pan) {
    if (pan == 0) return 'C';
    return '${pan < 0 ? 'L' : 'R'}${(pan.abs() * 100).round()}';
  }

  static String _dbEditText(double linear) {
    final db = AudioEdits.linearToDb(linear);
    if (db <= AudioEdits.kSilenceDb) return '-48';
    return db.toStringAsFixed(1);
  }

  static String _panEditText(double pan) {
    if (pan == 0) return 'C';
    return '${pan < 0 ? 'L' : 'R'}${(pan.abs() * 100).round()}';
  }
}

class _CurveRow extends StatelessWidget {
  const _CurveRow({
    required this.label,
    required this.selected,
    required this.labels,
    required this.onChanged,
  });

  final String label;
  final int selected;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: Row(
        children: [
          SizedBox(width: 78, child: Text(label, style: CcType.small)),
          Expanded(
            child: CcSegmented(
              expand: true,
              selectedIndex: selected,
              onChanged: onChanged,
              children: [
                for (final l in labels) Text(l, style: CcType.style(size: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.message, this.onDismiss});

  final IconData icon;
  final String message;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brSm,
      ),
      child: Row(
        children: [
          CcIcon(icon, size: 13, color: CcColors.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: CcType.style(size: 11, color: CcColors.textSecondary),
            ),
          ),
          if (onDismiss != null)
            CcTappable(
              onTap: onDismiss,
              child: const CcIcon(LucideIcons.x, size: 12),
            ),
        ],
      ),
    );
  }
}
