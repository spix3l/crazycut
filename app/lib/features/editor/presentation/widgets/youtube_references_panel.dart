import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../data/project.dart';
import '../../../../models/rational.dart';
import '../../../../state/editor_controller.dart';

class YouTubeReferencesPanel extends StatefulWidget {
  const YouTubeReferencesPanel({super.key, required this.controller});

  final EditorController controller;

  @override
  State<YouTubeReferencesPanel> createState() => _YouTubeReferencesPanelState();
}

class _YouTubeReferencesPanelState extends State<YouTubeReferencesPanel> {
  String? _selectedId;
  InAppWebViewController? _web;
  String? _playerError;

  MediaReference? get _selected {
    final references = widget.controller.doc.references;
    if (references.isEmpty) return null;
    final id = _selectedId;
    return references.firstWhere(
      (item) => item.id == id,
      orElse: () => references.first,
    );
  }

  Future<void> _mark({required bool out}) async {
    final reference = _selected;
    final web = _web;
    if (reference == null || web == null) return;
    try {
      final value = await web.evaluateJavascript(
        source: 'window.ccCurrentTime ? window.ccCurrentTime() : 0',
      );
      final seconds = value is num ? value.toDouble() : 0.0;
      widget.controller.updateReferenceRange(
        reference.id,
        rangeIn: out ? null : Rt.fromSeconds(seconds),
        rangeOut: out ? Rt.fromSeconds(seconds) : null,
      );
      if (mounted) setState(() {});
    } on Object catch (error) {
      if (mounted) setState(() => _playerError = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final references = widget.controller.doc.references;
    final selected = _selected;
    if (references.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CcIcon(
              LucideIcons.play,
              size: 28,
              color: CcColors.textTertiary,
            ),
            const SizedBox(height: 12),
            Text('No references yet', style: CcType.panelTitle),
            const SizedBox(height: 6),
            Text(
              'Add a YouTube URL to watch it here and note an in/out range.',
              textAlign: TextAlign.center,
              style: CcType.small,
            ),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (selected != null) ...[
            ClipRRect(
              borderRadius: CcRadius.brMd,
              child: SizedBox(
                height: 200,
                child: InAppWebView(
                  key: ValueKey(selected.externalId),
                  initialData: InAppWebViewInitialData(
                    data: _playerHtml(selected),
                    baseUrl: WebUri('https://dev.crazycut.crazycutapp'),
                  ),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    mediaPlaybackRequiresUserGesture: true,
                    allowsInlineMediaPlayback: true,
                    transparentBackground: false,
                  ),
                  onWebViewCreated: (controller) => _web = controller,
                  onReceivedError: (_, request, error) {
                    if (request.isForMainFrame != true || !mounted) return;
                    setState(() => _playerError = error.description);
                  },
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: CcButton(
                    label: 'Mark in',
                    kind: CcButtonKind.secondary,
                    onPressed: () => _mark(out: false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: CcButton(
                    label: 'Mark out',
                    kind: CcButtonKind.secondary,
                    onPressed: () => _mark(out: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Range  ${_time(selected.rangeIn)} — '
              '${selected.rangeOut == null ? 'not set' : _time(selected.rangeOut!)}',
              style: CcType.tiny,
              textAlign: TextAlign.center,
            ),
            if (_playerError != null) ...[
              const SizedBox(height: 8),
              Text(
                'Player unavailable. Open the reference in your browser.',
                style: CcType.style(size: 10, color: CcColors.warning),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
          ],
          Text('${references.length} references', style: CcType.tiny),
          const SizedBox(height: 8),
          for (final reference in references) ...[
            _ReferenceRow(
              reference: reference,
              selected: reference.id == selected?.id,
              onSelect:
                  () => setState(() {
                    _selectedId = reference.id;
                    _playerError = null;
                  }),
              onOpen: () => widget.controller.openExternalUrl(reference.url),
              onRemove: () => widget.controller.removeReference(reference.id),
            ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}

String _playerHtml(MediaReference reference) {
  final id = jsonEncode(reference.externalId);
  final start = reference.rangeIn.seconds.floor();
  return '''<!doctype html>
<html><head><meta name="referrer" content="strict-origin-when-cross-origin">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body,#player{width:100%;height:100%;margin:0;background:#090a0c;overflow:hidden}</style></head>
<body><div id="player"></div><script src="https://www.youtube.com/iframe_api"></script>
<script>
var player;
function onYouTubeIframeAPIReady(){player=new YT.Player('player',{videoId:$id,playerVars:{playsinline:1,start:$start,origin:'https://dev.crazycut.crazycutapp'}});}
window.ccCurrentTime=function(){return player&&player.getCurrentTime?player.getCurrentTime():0;};
</script></body></html>''';
}

String _time(Rt value) {
  final seconds = value.seconds.round();
  final minutes = seconds ~/ 60;
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _ReferenceRow extends StatelessWidget {
  const _ReferenceRow({
    required this.reference,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
    required this.onRemove,
  });

  final MediaReference reference;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => CcTappable(
    onTap: onSelect,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? CcColors.elevated2 : CcColors.elevated,
        borderRadius: CcRadius.brSm,
        border: Border.all(
          color: selected ? CcColors.accent : CcColors.borderStrong,
        ),
      ),
      child: Row(
        children: [
          const CcIcon(LucideIcons.play, size: 14, color: CcColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reference.externalId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CcType.style(size: 11, weight: CcType.medium),
            ),
          ),
          CcTappable(
            onTap: onOpen,
            child: const CcIcon(LucideIcons.externalLink, size: 13),
          ),
          const SizedBox(width: 8),
          CcTappable(
            onTap: onRemove,
            child: const CcIcon(LucideIcons.x, size: 13),
          ),
        ],
      ),
    ),
  );
}
