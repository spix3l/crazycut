import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/project.dart';
import '../../../../../models/rational.dart';
import '../../../../../state/editor_controller.dart';
import 'inspector_effects_tab.dart';
import 'inspector_rows.dart';
import 'inspector_text_tab.dart';
import 'inspector_transform_tab.dart';
import 'inspector_audio_tab.dart';
import 'inspector_tabs.dart';

/// Right rail. Binds to the current selection: sequence facts when nothing is
/// selected, otherwise the clip's timing, audio and (M2) look tabs.
class InspectorPanel extends StatefulWidget {
  const InspectorPanel({super.key, required this.controller});

  static const double width = 300;

  final EditorController controller;

  @override
  State<InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<InspectorPanel> {
  int _tab = 0;

  EditorController get c => widget.controller;

  static const _clipTabs = ['Timing', 'Audio', 'Transform', 'Effects'];
  static const _textClipTabs = ['Text', 'Transform', 'Effects'];

  @override
  Widget build(BuildContext context) {
    final selected = c.selectedClip;
    final multiple = c.selection.length > 1;
    final asset = selected == null ? null : c.doc.assetById(selected.mediaId);

    return Container(
      width: InspectorPanel.width,
      decoration: const BoxDecoration(color: CcColors.panel, border: CcBorders.left),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(border: CcBorders.bottom),
            child: Row(
              children: [
                if (selected != null) ...[
                  CcIcon(
                    asset?.type == 'audio'
                        ? LucideIcons.audioWaveform
                        : asset?.type == 'image'
                            ? LucideIcons.image
                            : LucideIcons.video,
                    size: 14,
                    color: CcColors.videoPlate2,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    selected == null
                        ? 'Sequence settings'
                        : multiple
                            ? '${c.selection.length} clips selected'
                            : selected.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CcType.bodyStrong,
                  ),
                ),
              ],
            ),
          ),
          if (selected != null)
            CcTabBar(
              tabs: selected.text != null ? _textClipTabs : _clipTabs,
              selectedIndex: _tab.clamp(0, _clipTabs.length - 1),
              fontSize: 11,
              horizontalPadding: 9,
              onChanged: (i) => setState(() => _tab = i),
            ),
          Expanded(
            child: SingleChildScrollView(
              child: selected == null
                  ? SequenceSettingsTab(controller: c)
                  : _clipBody(selected),
            ),
          ),
        ],
      ),
    );
  }

  Widget _clipBody(Clip clip) {
    if (clip.text != null && _clipTabs[_tab.clamp(0, _clipTabs.length - 1)] == 'Text') {
      return TextTab(controller: c, clip: clip);
    }
    return switch (_clipTabs[_tab.clamp(0, _clipTabs.length - 1)]) {
      'Timing' => ClipTimingTab(controller: c, clip: clip),
      'Audio' => ClipAudioTab(controller: c, clip: clip),
      'Transform' => TransformTab(controller: c, clip: clip),
      'Effects' => EffectsTab(controller: c, clip: clip),
      'Text' => TextTab(controller: c, clip: clip),
      _ => const PlaceholderTab(name: 'Text', note: 'Select a text clip to edit it.'),
    };
  }
}

/// Tabs that have no controls yet, kept honest about why.
class PlaceholderTab extends StatelessWidget {
  const PlaceholderTab({super.key, required this.name, required this.note});

  final String name;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CcSectionHeader(name.toUpperCase()),
          const SizedBox(height: 12),
          Text(note, style: CcType.style(size: 11, color: CcColors.textTertiary, height: 1.5)),
        ],
      ),
    );
  }
}

/// Sequence summary shown when nothing is selected.
class SequenceSettingsTab extends StatelessWidget {
  const SequenceSettingsTab({super.key, required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller.doc.settings;
    final fps = s.fpsValue;
    Widget value(String text) => Text(text, style: CcType.style(size: 12, weight: CcType.medium));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Nothing selected — select a clip on the timeline to edit its properties.',
            style: CcType.style(size: 11, color: CcColors.textTertiary, height: 1.4),
          ),
          const SizedBox(height: 24),
          InfoRow('Resolution', value('${s.width} × ${s.height}')),
          InfoRow(
            'Frame rate',
            value('${fps == fps.roundToDouble() ? fps.round() : fps.toStringAsFixed(2)} fps'),
          ),
          InfoRow('Sample rate', value('${(s.audioSampleRate / 1000).round()} kHz')),
          InfoRow('Duration', value(controller.durationTimecode)),
          InfoRow('Clips', value('${controller.doc.clips.length}')),
          InfoRow('Tracks', value('${controller.doc.tracks.length}')),
          if (controller.inPoint != null || controller.outPoint != null)
            InfoRow(
              'In / out',
              value(
                '${Rt.toTimecode(controller.rangeStart, fps)} → '
                '${Rt.toTimecode(controller.rangeEnd, fps)}',
              ),
            ),
          InfoRow(
            'Background',
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: const Color(0xFF000000),
                    borderRadius: BorderRadius.circular(3),
                    border: CcBorders.allStrong,
                  ),
                ),
                const SizedBox(width: 6),
                value(s.background),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const CcSectionHeader('LOUDNESS'),
          const SizedBox(height: 8),
          _LoudnessSection(controller: controller),
          const SizedBox(height: 20),
          const CcSectionHeader('MONITORING'),
          const SizedBox(height: 8),
          _OutputDeviceRow(controller: controller),
        ],
      ),
    );
  }
}

/// "Analyze sequence loudness" (AUD-12). The number comes from the same mix
/// the export writes, so it is the number the delivered file will measure.
class _LoudnessSection extends StatelessWidget {
  const _LoudnessSection({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final report = controller.loudness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (report != null) ...[
          InfoRow(
            'Integrated',
            Text(
              '${report.lufs.toStringAsFixed(1)} LUFS',
              style: CcType.style(size: 12, weight: CcType.medium),
            ),
          ),
          InfoRow(
            'True peak',
            Text(
              '${report.truePeakDb.toStringAsFixed(1)} dBTP',
              style: CcType.style(
                size: 12,
                weight: CcType.medium,
                color: report.truePeakDb > -1.0
                    ? CcColors.warning
                    : CcColors.textPrimary,
              ),
            ),
          ),
          InfoRow(
            'vs −14 LUFS',
            Text(
              '${report.lufs > -14 ? '+' : ''}'
              '${(report.lufs + 14).toStringAsFixed(1)} LU',
              style: CcType.style(size: 12, weight: CcType.medium),
            ),
          ),
          const SizedBox(height: 8),
        ],
        CcButton(
          label: controller.analyzingLoudness
              ? 'Analyzing…'
              : report == null
                  ? 'Analyze loudness'
                  : 'Re-analyze',
          kind: CcButtonKind.secondary,
          height: 30,
          radius: CcRadius.sm,
          onPressed: controller.analyzingLoudness
              ? null
              : () => controller.analyzeLoudness(),
        ),
      ],
    );
  }
}

/// Output device picker (AUD-14). Sample rate is locked at 48 kHz in v1.
class _OutputDeviceRow extends StatelessWidget {
  const _OutputDeviceRow({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final devices = controller.audioOutputDevices();
    if (devices.isEmpty) {
      return Text(
        'No audio output device found.',
        style: CcType.style(size: 11, color: CcColors.textTertiary),
      );
    }
    final current = controller.outputDeviceName.isEmpty
        ? devices.first
        : controller.outputDeviceName;
    return Builder(
      builder: (context) => CcTappable(
        onTap: () => showCcMenuBelow(
          context,
          [
            for (final device in devices)
              CcMenuItem(
                device,
                checked: device == current,
                onTap: () => controller.setOutputDevice(device),
              ),
          ],
        ),
        child: CcDropdown(value: current, height: 28, fontSize: 11),
      ),
    );
  }
}
