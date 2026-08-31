import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/modules/project/domain/area_track.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';
import 'inspector_effects_tab.dart';
import 'inspector_rows.dart';
import 'inspector_text_tab.dart';
import 'inspector_track_tab.dart';
import 'inspector_transform_tab.dart';
import 'inspector_audio_tab.dart';
import 'caption_editor_panel.dart';
import 'inspector_tabs.dart';

part 'placeholder_tab.dart';
part 'sequence_settings_tab.dart';

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
  String? _selectionKey;

  EditorController get c => widget.controller;

  /// Tabs follow what the clip actually has: an image has no audio to mix and
  /// a sound file has nothing to place on the canvas, and offering either is a
  /// dead end the user has to discover by clicking it.
  static List<String> _tabsFor(Clip? clip, MediaAsset? asset, bool trackable) {
    // A 'Track' tab only where there is something to track or something already
    // following one: audio has no region, and text has no source pixels to
    // solve against (TRK non-goals).
    final track = trackable ? const ['Track'] : const <String>[];
    if (clip == null) return const ['Timing', 'Audio', 'Transform', 'Effects'];
    if (clip.text != null) return const ['Text', 'Transform', 'Effects'];
    if (asset?.type == 'audio') return const ['Timing', 'Audio', 'Effects'];
    if (asset != null && !asset.hasAudio) {
      return ['Timing', 'Transform', ...track, 'Effects'];
    }
    return ['Timing', 'Audio', 'Transform', ...track, 'Effects'];
  }

  /// A clip can host the Track tab when it has rasterised source pixels of its
  /// own, or is already pinned to someone else's tracker.
  bool _trackable(Clip? clip, MediaAsset? asset) {
    if (clip == null || clip.text != null) return false;
    if (clip.extra.containsKey(kTrackPinKey)) return true;
    return asset != null && asset.type != 'audio';
  }

  @override
  Widget build(BuildContext context) {
    final selected = c.selectedClip;
    final selectedCaptionTrack = c.selectedCaptionTrack;
    final multiple = c.selection.length > 1;
    final asset = selected == null ? null : c.doc.assetById(selected.mediaId);
    final tabs = _tabsFor(selected, asset, _trackable(selected, asset));
    final selectionKey =
        selected == null ? null : '${selected.id}:${tabs.join(',')}';
    if (_selectionKey != selectionKey) {
      _selectionKey = selectionKey;
      _tab = 0;
    }
    final activeTab = _tab.clamp(0, tabs.length - 1);

    return Container(
      width: InspectorPanel.width,
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: CcBorders.left,
      ),
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
                    selected.text != null
                        ? LucideIcons.type
                        : asset?.type == 'audio'
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
                    selected == null && selectedCaptionTrack != null
                        ? selectedCaptionTrack.name
                        : selected == null
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
              tabs: tabs,
              selectedIndex: activeTab,
              fontSize: 11,
              horizontalPadding: 9,
              onChanged: (i) => setState(() => _tab = i),
            ),
          Expanded(
            child: SingleChildScrollView(
              child:
                  selected == null && selectedCaptionTrack != null
                      ? CaptionEditorPanel(controller: c)
                      : selected == null
                      ? SequenceSettingsTab(controller: c)
                      : _clipBody(selected, tabs[activeTab]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _clipBody(Clip clip, String tab) {
    return switch (tab) {
      'Timing' => ClipTimingTab(controller: c, clip: clip),
      'Audio' => ClipAudioTab(controller: c, clip: clip),
      'Transform' => TransformTab(controller: c, clip: clip),
      'Track' => TrackTab(controller: c, clip: clip),
      'Effects' => EffectsTab(controller: c, clip: clip),
      'Text' => TextTab(controller: c, clip: clip),
      _ => const PlaceholderTab(
        name: 'Text',
        note: 'Select a text clip to edit it.',
      ),
    };
  }
}
