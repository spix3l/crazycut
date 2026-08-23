import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../app/session.dart';
import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/cc_dialog.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../models/rational.dart';
import '../../../../state/export_presets.dart';
import '../../../../state/export_service.dart';
import '../widgets/export_preset_tile.dart';
import '../widgets/export_queue_panel.dart';

/// Export modal with the queue slide-over docked to the right edge.
///
/// Submitting snapshots the document (EXP-2) and hands it to
/// [ExportService]; the dialog can be closed and the editor keeps working
/// while the job renders in the worker process (EXP-10).
@RoutePage(name: 'ExportRoute')
class ExportDialogScreen extends StatefulWidget {
  const ExportDialogScreen({super.key, @QueryParam('empty') this.empty = false});

  /// The timeline is empty: exporting is disabled and the reason is shown.
  final bool empty;

  @override
  State<ExportDialogScreen> createState() => _ExportDialogScreenState();
}

class _ExportDialogScreenState extends State<ExportDialogScreen> {
  static const _icons = [
    LucideIcons.monitorPlay,
    LucideIcons.monitor,
    LucideIcons.smartphone,
    LucideIcons.camera,
    LucideIcons.clapperboard,
    LucideIcons.slidersHorizontal,
  ];

  final ExportService _service = ExportService.instance;

  int _presetIndex = 0;
  late ExportQuality _quality;
  late bool _loudness;
  bool _levelClips = false;
  bool _matchExposure = false;
  bool _hardware = false;
  bool _rangeOnly = false;
  String? _outputPath;

  ExportPreset get _preset => ExportPreset.all[_presetIndex];

  @override
  void initState() {
    super.initState();
    _quality = _preset.quality;
    _loudness = _preset.loudnessDefault;
    _service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  void _close() => context.router.maybePop();

  void _selectPreset(int index) {
    setState(() {
      _presetIndex = index;
      _quality = _preset.quality;
      _loudness = _preset.loudnessDefault;
      _outputPath = null;  // recompute the default name for the new preset
    });
  }

  String _defaultPath() {
    final session = AppSession.instance;
    final name = session.project?.name ?? 'Sequence';
    final projectPath = session.path;
    final directory = projectPath != null
        ? File(projectPath).parent.path
        : (Platform.environment['HOME'] ?? '.');
    return '$directory${Platform.pathSeparator}'
        '${_preset.defaultFilename(name)}';
  }

  String get _path => _outputPath ?? _defaultPath();

  Future<void> _browse() async {
    final location = await getSaveLocation(
      suggestedName: _path.split(Platform.pathSeparator).last,
      acceptedTypeGroups: [
        XTypeGroup(label: _preset.container.toUpperCase(),
            extensions: [_preset.container]),
      ],
    );
    if (location == null) return;
    setState(() => _outputPath = location.path);
  }

  void _submit() {
    final session = AppSession.instance;
    if (!session.hasProject) return;
    final controller = session.editor;
    final hasRange =
        controller.inPoint != null || controller.outPoint != null;

    _service.submit(
      doc: controller.doc,
      preset: _preset,
      // EXP integrity: never silently overwrite an existing file.
      outputPath: ExportService.uniquePath(_path),
      quality: _quality,
      hardware: _hardware,
      loudness: _loudness,
      levelClips: _levelClips,
      matchExposure: _matchExposure,
      rangeStart: _rangeOnly && hasRange ? controller.rangeStart : null,
      rangeEnd: _rangeOnly && hasRange ? controller.rangeEnd : Rt.zero(),
    );
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final session = AppSession.instance;
    final settings = session.project?.settings;
    final controller = session.hasProject ? session.editor : null;
    final hasRange =
        controller != null && (controller.inPoint != null || controller.outPoint != null);
    final offline = controller?.offlineAssets ?? const [];
    final (outWidth, outHeight) =
        settings == null ? (0, 0) : _preset.outputSize(settings);
    final duration = _rangeOnly && hasRange
        ? controller.rangeEnd.seconds - controller.rangeStart.seconds
        : (controller?.duration.seconds ?? 0);

    final blocked = widget.empty || duration <= 0;

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
                                  final preset = ExportPreset.all[index];
                                  return ExportPresetTile(
                                    icon: _icons[index],
                                    name: preset.name,
                                    subtitle: preset.subtitle,
                                    selected: _presetIndex == index,
                                    onTap: () => _selectPreset(index),
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
                  value: _path,
                  trailing: CcLink('Browse', onTap: _browse),
                ),
              ),
              _QualitySlider(
                quality: _quality,
                onChanged: (q) => setState(() => _quality = q),
              ),
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
              const SizedBox(height: 8),
              Row(
                children: [
                  _Option(
                    label: 'Level clip volumes',
                    checked: _levelClips,
                    onTap: () => setState(() => _levelClips = !_levelClips),
                  ),
                  const SizedBox(width: 24),
                  _Option(
                    label: 'Match clip exposure',
                    checked: _matchExposure,
                    onTap: () =>
                        setState(() => _matchExposure = !_matchExposure),
                  ),
                ],
              ),
              if (hasRange)
                _Option(
                  label: 'In/out range only '
                      '(${Rt.toTimecode(controller.rangeStart, controller.fps)} → '
                      '${Rt.toTimecode(controller.rangeEnd, controller.fps)})',
                  checked: _rangeOnly,
                  onTap: () => setState(() => _rangeOnly = !_rangeOnly),
                ),
              if (offline.isNotEmpty)
                _Warning(
                  message: '${offline.length} offline '
                      '${offline.length == 1 ? 'clip renders' : 'clips render'} '
                      'as slates. Relink them first for a clean export.',
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
                    Text(
                      settings == null
                          ? 'No sequence'
                          : '$outWidth×$outHeight · '
                              '${_fpsLabel(settings.fpsValue)} · '
                              '${_durationLabel(duration)}',
                      style: CcType.tiny,
                    ),
                    const Spacer(),
                    Text(
                      'Estimated size: ${_estimate(outWidth, outHeight, duration)}',
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
                onPressed: blocked ? null : _submit,
              ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: ExportQueuePanel(service: _service, onClose: _close),
        ),
      ],
    );
  }

  static String _fpsLabel(double fps) =>
      '${fps == fps.roundToDouble() ? fps.round() : fps.toStringAsFixed(2)}fps';

  static String _durationLabel(double seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).floor();
    return '$m:${s.toString().padLeft(2, '0')} duration';
  }

  /// Rough bits-per-pixel estimate, labelled as an estimate (EXP-8). A sample
  /// encode would be more accurate but costs seconds before the dialog is
  /// usable.
  String _estimate(int width, int height, double seconds) {
    if (width <= 0 || seconds <= 0) return '—';
    final bpp = switch (_preset.videoCodec) {
      'prores' => 1.6,
      _ => switch (_quality) {
          ExportQuality.draft => 0.04,
          ExportQuality.web => 0.07,
          ExportQuality.high => 0.11,
          ExportQuality.master => 0.18,
        },
    };
    final fps = AppSession.instance.project?.settings.fpsValue ?? 30;
    final videoBits = width * height * fps * bpp;
    final audioBits = _preset.audioCodec == 'pcm' ? 48000 * 24 * 2 : 320000;
    final bytes = ((videoBits + audioBits) / 8) * seconds;
    if (bytes >= 1024 * 1024 * 1024) {
      return '~${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '~${(bytes / (1024 * 1024)).round()} MB';
  }
}

class _QualitySlider extends StatelessWidget {
  const _QualitySlider({required this.quality, required this.onChanged});

  final ExportQuality quality;
  final ValueChanged<ExportQuality> onChanged;

  @override
  Widget build(BuildContext context) {
    const values = ExportQuality.values;
    final index = values.indexOf(quality);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Quality', style: CcType.label),
            const Spacer(),
            Text(quality.label,
                style: CcType.style(size: 12, weight: CcType.semibold)),
          ],
        ),
        const SizedBox(height: 10),
        CcSlider(
          value: index / (values.length - 1),
          handleSize: 12,
          onChanged: (v) => onChanged(
            values[(v * (values.length - 1)).round().clamp(0, values.length - 1)],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var i = 0; i < values.length; i++) ...[
              if (i > 0) const Spacer(),
              Text(
                values[i].label,
                style: CcType.style(
                  size: 10,
                  color: i == index ? CcColors.textPrimary : CcColors.textTertiary,
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

class _Warning extends StatelessWidget {
  const _Warning({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brSm,
      ),
      child: Row(
        children: [
          const CcIcon(LucideIcons.triangleAlert, size: 13, color: CcColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: CcType.style(size: 11, color: CcColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
