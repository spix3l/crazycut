import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';

import '../../../../app/router/app_router.gr.dart';
import '../../../../core/design/tokens.dart';
import '../models/editor_models.dart';
import '../widgets/editor_toolbar.dart';
import '../widgets/inspector/inspector_panel.dart';
import '../widgets/media_pool.dart';
import '../widgets/monitor_panel.dart';
import '../widgets/timeline/timeline_panel.dart';

/// The editor: toolbar on top, media pool / monitor / inspector in the middle,
/// timeline at the bottom. [empty] renders the fresh-project variant.
@RoutePage()
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, @QueryParam('empty') this.empty = false});

  final bool empty;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  int _tool = 0;
  String? _selectedKey;

  InspectorTarget get _target {
    final key = _selectedKey;
    if (widget.empty) return InspectorTarget.none;
    if (key == null) return InspectorTarget.caption;
    if (key.endsWith('#transition')) return InspectorTarget.transition;
    return key.startsWith('V2/') ? InspectorTarget.caption : InspectorTarget.clip;
  }

  @override
  Widget build(BuildContext context) {
    final empty = widget.empty;
    return ColoredBox(
      color: CcColors.bg,
      child: Column(
        children: [
          EditorToolbar(
            selectedTool: _tool,
            onToolChanged: (i) => setState(() => _tool = i),
            onBack: () => context.router.maybePop(),
            onExport: () => context.router.push(ExportRoute(empty: empty)),
          ),
          Expanded(
            flex: 560,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MediaPool(assets: empty ? const [] : sampleAssets),
                Expanded(child: MonitorPanel(empty: empty)),
                InspectorPanel(key: ValueKey(_target), selection: _target),
              ],
            ),
          ),
          Expanded(
            flex: 388,
            child: TimelinePanel(
              tracks: empty ? emptyTracks : sampleTracks,
              playheadSeconds: empty ? 0 : 12.1,
              showGettingStartedHint: empty,
              selectedKey: _selectedKey,
              onSelect: (key) => setState(() => _selectedKey = key),
            ),
          ),
        ],
      ),
    );
  }
}
