part of 'inspector_panel.dart';

/// Sequence summary shown when nothing is selected.
class SequenceSettingsTab extends StatelessWidget {
  const SequenceSettingsTab({super.key, required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller.doc.settings;
    final fps = s.fpsValue;
    Widget value(String text) => Text(text, style: CcType.value);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Nothing selected. Select a clip on the timeline to edit its properties.',
            style: CcType.style(
              size: 11,
              color: CcColors.textTertiary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          InfoRow('Resolution', value('${s.width} × ${s.height}')),
          InfoRow(
            'Frame rate',
            value(
              '${fps == fps.roundToDouble() ? fps.round() : fps.toStringAsFixed(2)} fps',
            ),
          ),
          InfoRow(
            'Sample rate',
            value('${(s.audioSampleRate / 1000).round()} kHz'),
          ),
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
            Text('${report.lufs.toStringAsFixed(1)} LUFS', style: CcType.value),
          ),
          InfoRow(
            'True peak',
            Text(
              '${report.truePeakDb.toStringAsFixed(1)} dBTP',
              style: CcType.value.copyWith(
                color:
                    report.truePeakDb > -1.0
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
              style: CcType.value,
            ),
          ),
          const SizedBox(height: 8),
        ],
        CcButton(
          label:
              controller.analyzingLoudness
                  ? 'Analyzing…'
                  : report == null
                  ? 'Analyze loudness'
                  : 'Re-analyze',
          kind: CcButtonKind.secondary,
          height: 30,
          radius: CcRadius.sm,
          onPressed:
              controller.analyzingLoudness
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
    final current =
        controller.outputDeviceName.isEmpty
            ? devices.first
            : controller.outputDeviceName;
    return Builder(
      builder:
          (context) => CcDropdown(
            value: current,
            width: double.infinity,
            height: 28,
            fontSize: 11,
            onTap:
                () => showCcMenu(context, [
                  for (final device in devices)
                    CcMenuItem(
                      device,
                      checked: device == current,
                      onTap: () => controller.setOutputDevice(device),
                    ),
                ]),
          ),
    );
  }
}
