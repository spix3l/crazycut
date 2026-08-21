import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/cc_dialog.dart';
import '../../../../core/widgets/primitives.dart';
import '../models/export_job.dart';
import '../widgets/export_preset_tile.dart';
import '../widgets/export_queue_panel.dart';

/// Export modal with the queue slide-over docked to the right edge.
@RoutePage(name: 'ExportRoute')
class ExportDialogScreen extends StatefulWidget {
  const ExportDialogScreen({super.key, @QueryParam('empty') this.empty = false});

  /// Renders the queue in its empty state (fresh install / nothing exported).
  final bool empty;

  @override
  State<ExportDialogScreen> createState() => _ExportDialogScreenState();
}

class _ExportDialogScreenState extends State<ExportDialogScreen> {
  static const _presets = [
    (icon: LucideIcons.monitorPlay, name: 'YouTube 1080p', sub: 'H.264 · AAC'),
    (icon: LucideIcons.monitor, name: 'YouTube 4K', sub: 'H.264/HEVC · AAC'),
    (icon: LucideIcons.smartphone, name: 'Shorts/TikTok/Reels', sub: '1080×1920 · AAC'),
    (icon: LucideIcons.camera, name: 'Instagram Feed', sub: '1080×1350 · AAC'),
    (icon: LucideIcons.clapperboard, name: 'Master (ProRes)', sub: 'MOV · PCM 24-bit'),
    (icon: LucideIcons.slidersHorizontal, name: 'Custom', sub: 'Set your own'),
  ];

  int _preset = 0;
  bool _loudness = true;
  bool _hardware = false;

  void _close() => context.router.maybePop();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        CcModalBarrier(
          color: CcColors.scrimStrong,
          onDismiss: _close,
          padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
          child: CcDialogShell(
            title: 'Export',
            width: 640,
            onClose: _close,
            gap: 18,
            sections: [
              CcField(
                label: 'Preset',
                child: Column(
                  children: [
                    for (var row = 0; row < 2; row++) ...[
                      if (row > 0) const SizedBox(height: 8),
                      Row(
                        children: [
                          for (var col = 0; col < 3; col++) ...[
                            if (col > 0) const SizedBox(width: 9),
                            Expanded(
                              child: Builder(
                                builder: (context) {
                                  final index = row * 3 + col;
                                  final preset = _presets[index];
                                  return ExportPresetTile(
                                    icon: preset.icon,
                                    name: preset.name,
                                    subtitle: preset.sub,
                                    selected: _preset == index,
                                    onTap: () => setState(() => _preset = index),
                                  );
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              CcField(
                label: 'Filename & location',
                child: CcTextField(
                  value: 'Beauty Routine Ep. 12 [YouTube 1080p].mp4',
                  trailing: CcLink('Browse', onTap: () {}),
                ),
              ),
              const _QualitySlider(),
              Row(
                children: [
                  _Option(
                    label: 'Loudness normalize (−14 LUFS)',
                    checked: _loudness,
                    onTap: () => setState(() => _loudness = !_loudness),
                  ),
                  const SizedBox(width: 24),
                  _Option(
                    label: 'Hardware encoding',
                    checked: _hardware,
                    onTap: () => setState(() => _hardware = !_hardware),
                  ),
                ],
              ),
              Container(
                height: 33,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: const BoxDecoration(
                  color: CcColors.elevated,
                  borderRadius: CcRadius.brSm,
                ),
                child: Row(
                  children: [
                    Text('1920×1080 · 30fps · 12:34 duration', style: CcType.tiny),
                    const Spacer(),
                    Text(
                      'Estimated size: ~340 MB',
                      style: CcType.style(size: 11, weight: CcType.medium),
                    ),
                  ],
                ),
              ),
            ],
            actions: [
              CcButton(
                label: 'Cancel',
                kind: CcButtonKind.secondary,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                onPressed: _close,
              ),
              CcButton(
                label: 'Add to queue',
                icon: LucideIcons.upload,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                onPressed: () {},
              ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: ExportQueuePanel(
            jobs: widget.empty ? const [] : sampleJobs,
            onClose: _close,
          ),
        ),
      ],
    );
  }
}

class _QualitySlider extends StatelessWidget {
  const _QualitySlider();

  static const _ticks = ['Draft', 'Web', 'High', 'Master'];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Quality', style: CcType.label),
            const Spacer(),
            Text('High', style: CcType.style(size: 12, weight: CcType.semibold)),
          ],
        ),
        const SizedBox(height: 10),
        const CcSlider(value: 0.745, handleSize: 12),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var i = 0; i < _ticks.length; i++) ...[
              if (i > 0) const Spacer(),
              Text(
                _ticks[i],
                style: CcType.style(
                  size: 10,
                  color: _ticks[i] == 'High' ? CcColors.textPrimary : CcColors.textTertiary,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.label, required this.checked, this.onTap});

  final String label;
  final bool checked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CcCheckbox(checked: checked, onTap: onTap),
          const SizedBox(width: 8),
          Text(label, style: CcType.small),
        ],
      ),
    );
  }
}
