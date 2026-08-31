import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/cc_dialog.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';
import 'package:crazycut_app/modules/media/application/media_relink.dart';

/// "Missing media" panel (IMP-15/16): what is offline, and one action that
/// relinks a whole folder by content hash.
Future<void> showMissingMediaDialog(
  BuildContext context,
  EditorController controller,
) {
  final completer = Completer<void>();
  final overlay = Overlay.of(context);
  late OverlayEntry entry;

  void finish() {
    if (completer.isCompleted) return;
    entry.remove();
    completer.complete();
  }

  entry = OverlayEntry(
    builder:
        (context) => CcModalBarrier(
          onDismiss: finish,
          child: _MissingMediaDialog(controller: controller, onClose: finish),
        ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _MissingMediaDialog extends StatefulWidget {
  const _MissingMediaDialog({required this.controller, required this.onClose});

  final EditorController controller;
  final VoidCallback onClose;

  @override
  State<_MissingMediaDialog> createState() => _MissingMediaDialogState();
}

class _MissingMediaDialogState extends State<_MissingMediaDialog> {
  RelinkPlan? _plan;
  bool _scanning = false;
  String? _status;

  List<MediaAsset> get _missing => widget.controller.offlineAssets;

  Future<void> _locateFolder() async {
    final directory = await getDirectoryPath();
    if (directory == null) return;
    await _scan([directory]);
  }

  Future<void> _locateFiles() async {
    final files = await openFiles();
    if (files.isEmpty) return;
    await _scan(files.map((f) => f.path).toList());
  }

  Future<void> _scan(List<String> paths) async {
    setState(() {
      _scanning = true;
      _status = 'Scanning…';
    });
    // Hashing reads whole files; keep it off the UI thread's critical path by
    // yielding first so the spinner state paints.
    await Future<void>.delayed(Duration.zero);
    final candidates = MediaRelinker.gatherCandidates(paths);
    final plan = widget.controller.dependencies.mediaRelinker.plan(
      _missing,
      candidates,
    );
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _scanning = false;
      _status =
          '${candidates.length} file${candidates.length == 1 ? '' : 's'} '
          'scanned · ${plan.summary}';
    });
  }

  Future<void> _apply() async {
    final plan = _plan;
    if (plan == null) return;
    for (final match in plan.matches) {
      await widget.controller.relinkAsset(match.assetId, match.path);
    }
    if (!mounted) return;
    final remaining = _missing.length;
    setState(() {
      _plan = null;
      _status =
          remaining == 0 ? 'All media relinked.' : '$remaining still missing.';
    });
    if (remaining == 0) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final missing = _missing;

    return CcDialogShell(
      title: 'Missing media',
      width: 560,
      onClose: widget.onClose,
      sections: [
        Text(
          missing.isEmpty
              ? 'Everything is online.'
              : '${missing.length} asset${missing.length == 1 ? '' : 's'} '
                  'could not be found. Clips keep their edits and render as '
                  'slates until relinked.',
          style: CcType.style(
            size: 12,
            color: CcColors.textSecondary,
            height: 1.4,
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final asset in missing)
                _MissingRow(
                  asset: asset,
                  match:
                      plan?.matches
                          .where((m) => m.assetId == asset.id)
                          .firstOrNull,
                ),
            ],
          ),
        ),
        if (_status != null)
          Text(
            _status!,
            style: CcType.style(size: 11, color: CcColors.textTertiary),
          ),
      ],
      actions: [
        CcButton(
          label: 'Locate file…',
          kind: CcButtonKind.secondary,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          onPressed: _scanning ? null : _locateFiles,
        ),
        const SizedBox(width: 8),
        CcButton(
          label: 'Locate folder…',
          kind: CcButtonKind.secondary,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          onPressed: _scanning ? null : _locateFolder,
        ),
        const SizedBox(width: 8),
        CcButton(
          label: plan == null ? 'Relink' : 'Relink ${plan.matches.length}',
          icon: LucideIcons.link,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          onPressed: plan == null || plan.isEmpty ? null : _apply,
        ),
      ],
    );
  }
}

class _MissingRow extends StatelessWidget {
  const _MissingRow({required this.asset, this.match});

  final MediaAsset asset;
  final RelinkMatch? match;

  @override
  Widget build(BuildContext context) {
    final size = _sizeLabel(asset);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CcIcon(
            match == null ? LucideIcons.fileQuestion : LucideIcons.fileCheck,
            size: 14,
            color: match == null ? CcColors.warning : CcColors.success,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  asset.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.style(size: 12, weight: CcType.medium),
                ),
                Text(
                  match?.path ?? asset.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.style(size: 10, color: CcColors.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (match != null)
            CcBadge(
              match!.confidence == RelinkConfidence.exact ? 'hash' : 'name',
              fontSize: 9,
            )
          else if (size != null)
            Text(
              size,
              style: CcType.style(size: 10, color: CcColors.textTertiary),
            ),
        ],
      ),
    );
  }

  static String? _sizeLabel(MediaAsset asset) {
    final file = File(asset.path);
    if (!file.existsSync()) return null;
    return '${(file.lengthSync() / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
