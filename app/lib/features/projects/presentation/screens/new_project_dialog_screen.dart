import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';

import '../../../../app/router/app_router.gr.dart';
import '../../../../app/session.dart';
import '../../../../core/widgets/cc_dialog.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../data/repository.dart';
import '../widgets/preset_tile.dart';

/// "New project" modal — name, aspect preset, destination folder.
@RoutePage(name: 'NewProjectRoute')
class NewProjectDialogScreen extends StatefulWidget {
  const NewProjectDialogScreen({super.key});

  @override
  State<NewProjectDialogScreen> createState() => _NewProjectDialogScreenState();
}

typedef _Preset = ({
  String title,
  String subtitle,
  Size swatch,
  int width,
  int height,
  double fps,
});

class _NewProjectDialogScreenState extends State<NewProjectDialogScreen> {
  static const List<_Preset> _presets = [
    (
      title: 'YouTube',
      subtitle: '1920×1080 · 30/60',
      swatch: Size(28, 16),
      width: 1920,
      height: 1080,
      fps: 30,
    ),
    (
      title: 'Shorts / TikTok / Reels',
      subtitle: '1080×1920 · 30/60',
      swatch: Size(13, 24),
      width: 1080,
      height: 1920,
      fps: 30,
    ),
    (
      title: 'Square',
      subtitle: '1080×1080 · 30',
      swatch: Size(20, 20),
      width: 1080,
      height: 1080,
      fps: 30,
    ),
    (
      title: 'Custom',
      subtitle: 'Set your own',
      swatch: Size(22, 16),
      width: 1920,
      height: 1080,
      fps: 30,
    ),
  ];

  late final TextEditingController _name = TextEditingController(text: _defaultName());
  String _location = 'Documents/CrazyCut';
  int _selected = 0;
  bool _creating = false;

  static String _defaultName() {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final now = DateTime.now();
    return 'Untitled, ${months[now.month - 1]} ${now.day}';
  }

  @override
  void initState() {
    super.initState();
    ProjectRepository.projectsDir().then((dir) {
      if (mounted) setState(() => _location = dir.path);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _close() => context.router.maybePop();

  Future<void> _create() async {
    if (_creating) return;
    setState(() => _creating = true);
    final preset = _presets[_selected];
    await AppSession.instance.createNew(
      name: _name.text.trim(),
      width: preset.width,
      height: preset.height,
      fps: preset.fps,
    );
    if (!mounted) return;
    await context.router.replace(EditorRoute());
  }

  @override
  Widget build(BuildContext context) {
    return CcModalBarrier(
      onDismiss: _close,
      child: CcDialogShell(
        title: 'New project',
        width: 600,
        onClose: _close,
        sections: [
          CcField(
            label: 'Name',
            child: CcTextField(
              controller: _name,
              autofocus: true,
              onSubmitted: (_) => _create(),
            ),
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
            child: CcTextField(value: _location),
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
            label: _creating ? 'Creating…' : 'Create project',
            padding: const EdgeInsets.symmetric(horizontal: 18),
            onPressed: _create,
          ),
        ],
      ),
    );
  }
}
