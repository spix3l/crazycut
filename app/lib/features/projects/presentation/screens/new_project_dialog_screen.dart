import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';

import '../../../../app/router/app_router.gr.dart';
import '../../../../core/widgets/cc_dialog.dart';
import '../../../../core/widgets/primitives.dart';
import '../widgets/preset_tile.dart';

/// "New project" modal — name, aspect preset, destination folder.
@RoutePage(name: 'NewProjectRoute')
class NewProjectDialogScreen extends StatefulWidget {
  const NewProjectDialogScreen({super.key});

  @override
  State<NewProjectDialogScreen> createState() => _NewProjectDialogScreenState();
}

class _NewProjectDialogScreenState extends State<NewProjectDialogScreen> {
  static const _presets = [
    (title: 'YouTube', subtitle: '1920×1080 · 30/60', swatch: Size(28, 16)),
    (title: 'Shorts / TikTok / Reels', subtitle: '1080×1920 · 30/60', swatch: Size(13, 24)),
    (title: 'Square', subtitle: '1080×1080 · 30', swatch: Size(20, 20)),
    (title: 'Custom', subtitle: 'Set your own', swatch: Size(22, 16)),
  ];

  int _selected = 0;

  void _close() => context.router.maybePop();

  @override
  Widget build(BuildContext context) {
    return CcModalBarrier(
      onDismiss: _close,
      child: CcDialogShell(
        title: 'New project',
        width: 600,
        onClose: _close,
        sections: [
          const CcField(
            label: 'Name',
            child: CcTextField(value: 'Untitled — Aug 21'),
          ),
          CcField(
            label: 'Preset',
            child: Column(
              children: [
                for (var row = 0; row < 2; row++) ...[
                  if (row > 0) const SizedBox(height: 8),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var col = 0; col < 2; col++) ...[
                          if (col > 0) const SizedBox(width: 12),
                          Expanded(
                            child: Builder(
                              builder: (context) {
                                final index = row * 2 + col;
                                final preset = _presets[index];
                                return PresetTile(
                                  title: preset.title,
                                  subtitle: preset.subtitle,
                                  swatchSize: preset.swatch,
                                  selected: _selected == index,
                                  onTap: () => setState(() => _selected = index),
                                );
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          CcField(
            label: 'Location',
            child: CcTextField(
              value: 'Documents/CrazyCut',
              trailing: CcLink('Change', onTap: () {}),
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
            label: 'Create project',
            padding: const EdgeInsets.symmetric(horizontal: 18),
            onPressed: () => context.router.replace(EditorRoute(empty: true)),
          ),
        ],
      ),
    );
  }
}
