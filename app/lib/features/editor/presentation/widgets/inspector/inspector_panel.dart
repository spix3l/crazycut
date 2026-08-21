import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import 'inspector_row.dart';
import 'inspector_tabs.dart';

/// What the inspector is currently bound to. Each selection brings its own
/// header, tab set and tab bodies.
enum InspectorTarget { caption, clip, transition, none }

/// Right rail. With [InspectorTarget.none] it shows sequence settings.
class InspectorPanel extends StatefulWidget {
  const InspectorPanel({super.key, this.selection = InspectorTarget.caption});

  static const double width = 300;

  final InspectorTarget selection;

  @override
  State<InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<InspectorPanel> {
  late int _tab = _initialTab;

  int get _initialTab => switch (widget.selection) {
        InspectorTarget.caption => 1,
        InspectorTarget.clip => 2,
        _ => 0,
      };

  List<String> get _tabs => switch (widget.selection) {
        InspectorTarget.caption => const ['Text', 'Transform', 'Effects', 'Timing'],
        InspectorTarget.clip => const ['Transform', 'Color', 'Effects', 'Speed', 'Audio'],
        InspectorTarget.transition => const ['Transition'],
        InspectorTarget.none => const [],
      };

  (IconData?, Color, String) get _header => switch (widget.selection) {
        InspectorTarget.caption => (LucideIcons.type, CcColors.textClip, 'Caption Text'),
        InspectorTarget.clip => (LucideIcons.video, CcColors.videoPlate2, 'broll_desk.mp4'),
        InspectorTarget.transition => (
            LucideIcons.hourglass,
            CcColors.videoPlate2,
            'Cross Dissolve'
          ),
        InspectorTarget.none => (null, CcColors.textPrimary, 'Sequence settings'),
      };

  @override
  Widget build(BuildContext context) {
    final (icon, iconColor, title) = _header;
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
                if (icon != null) ...[
                  CcIcon(icon, size: 14, color: iconColor),
                  const SizedBox(width: 8),
                ],
                Text(title, style: CcType.bodyStrong),
              ],
            ),
          ),
          if (_tabs.isNotEmpty)
            CcTabBar(
              tabs: _tabs,
              selectedIndex: _tab,
              fontSize: widget.selection == InspectorTarget.clip ? 11 : 12,
              horizontalPadding: widget.selection == InspectorTarget.clip ? 9 : 10,
              onChanged: (i) => setState(() => _tab = i),
            ),
          Expanded(child: SingleChildScrollView(child: _body())),
        ],
      ),
    );
  }

  Widget _body() {
    if (widget.selection == InspectorTarget.none) return const SequenceSettingsTab();
    if (widget.selection == InspectorTarget.transition) return const TransitionTab();
    final name = _tabs[_tab];
    return switch (name) {
      'Transform' => const TransformTab(),
      'Effects' => const EffectsTab(),
      'Timing' => const TimingTab(),
      _ => PlaceholderTab(name: name),
    };
  }
}

/// Tabs that carry no design of their own yet.
class PlaceholderTab extends StatelessWidget {
  const PlaceholderTab({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CcSectionHeader(name.toUpperCase()),
          const SizedBox(height: 12),
          Text('No controls in this mock-up.', style: CcType.tiny),
        ],
      ),
    );
  }
}

/// Sequence summary shown when nothing is selected.
class SequenceSettingsTab extends StatelessWidget {
  const SequenceSettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    Widget row(String label, Widget value) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Text(label, style: CcType.small),
              const Spacer(),
              value,
            ],
          ),
        );

    Widget value(String text) =>
        Text(text, style: CcType.style(size: 12, weight: CcType.medium));

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
          row('Resolution', value('1920 × 1080')),
          row('Frame rate', value('30 fps')),
          row('Sample rate', value('48 kHz')),
          row('Duration', value('00:00:00:00')),
          row(
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
                value('#000000'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Position / scale / rotation / opacity sliders.
class TransformTab extends StatelessWidget {
  const TransformTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: CcSectionHeader('TRANSFORM'),
          ),
          const InspectorRow(label: 'Position X', value: '0', progress: 0.55),
          const InspectorRow(label: 'Position Y', value: '-120', progress: 0.52),
          const InspectorRow(label: 'Scale', value: '100%', progress: 0.55, keyframed: true),
          const InspectorRow(label: 'Rotation', value: '0°', progress: 0.55),
          const InspectorRow(label: 'Opacity', value: '100%', progress: 1),
        ],
      ),
    );
  }
}
