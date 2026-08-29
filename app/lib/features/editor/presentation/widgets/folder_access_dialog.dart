import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/cc_dialog.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../state/editor_controller.dart';
import '../../../../state/sandbox_access.dart';

/// Asks for the folder grants this project needs (macOS App Sandbox).
///
/// macOS scopes file access to what the user picked, for the run they picked
/// it in, so a project whose media and project file live outside CrazyCut's
/// own folder loses reach on every relaunch. Handing back the *folder* — not
/// each file — is what restores it for good: a folder grant covers everything
/// inside and permits the sibling `.tmp` a save writes.
Future<void> showFolderAccessDialog(
  BuildContext context,
  EditorController controller,
  List<FolderRequest> requests,
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
    builder: (context) => CcModalBarrier(
      onDismiss: finish,
      child: _FolderAccessDialog(
        controller: controller,
        requests: requests,
        onClose: finish,
      ),
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _FolderAccessDialog extends StatefulWidget {
  const _FolderAccessDialog({
    required this.controller,
    required this.requests,
    required this.onClose,
  });

  final EditorController controller;
  final List<FolderRequest> requests;
  final VoidCallback onClose;

  @override
  State<_FolderAccessDialog> createState() => _FolderAccessDialogState();
}

class _FolderAccessDialogState extends State<_FolderAccessDialog> {
  final _granted = <String>{};
  String? _status;

  List<FolderRequest> get _pending =>
      widget.requests.where((r) => !_granted.contains(r.folder)).toList();

  /// The picker is the only thing that can hand us a folder grant: the dialog
  /// opens at the folder we need, and the user confirms it.
  Future<void> _grant(FolderRequest request) async {
    final picked = await getDirectoryPath(initialDirectory: request.folder);
    if (picked == null) return;

    // Picking a parent works too — a grant covers everything beneath it — but
    // picking something unrelated leaves the folder just as unreachable, and
    // saying so beats silently doing nothing.
    await SandboxAccess.instance.remember(picked);
    final ok = request.needsWrite
        ? SandboxAccess.instance.canWrite(request.folder)
        : SandboxAccess.instance.canRead(request.folder);
    if (!mounted) return;

    if (!ok) {
      setState(() {
        _status = 'That folder doesn’t cover “${request.name}”. '
            'Pick “${request.name}” itself, or a folder containing it.';
      });
      return;
    }

    widget.controller.recheckOfflineAssets();
    setState(() {
      _granted.add(request.folder);
      _status = null;
    });
    if (_pending.isEmpty) {
      // Everything is reachable again; a save now has somewhere to land.
      unawaited(widget.controller.saveNow());
      widget.onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    final writes = widget.requests.where((r) => r.needsWrite).isNotEmpty;

    return CcDialogShell(
      title: 'Grant folder access',
      width: 560,
      onClose: widget.onClose,
      sections: [
        Text(
          'macOS only lets CrazyCut open files you pick, and only until it '
          'quits. Nothing has moved — this project just needs its folders '
          'handed back once. Each grant is remembered from then on.',
          style: CcType.style(
            size: 12,
            color: CcColors.textSecondary,
            height: 1.4,
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final request in widget.requests)
                _FolderRow(
                  request: request,
                  granted: _granted.contains(request.folder),
                  onGrant: () => _grant(request),
                ),
            ],
          ),
        ),
        if (_status != null)
          Text(
            _status!,
            style: CcType.style(
              size: 11,
              color: CcColors.warning,
              height: 1.4,
            ),
          ),
        if (pending.isNotEmpty && writes)
          Text(
            'Until the project folder is granted, edits stay in memory and '
            'saving will keep failing.',
            style: CcType.style(
              size: 11,
              color: CcColors.textTertiary,
              height: 1.4,
            ),
          ),
      ],
      actions: [
        CcButton(
          label: pending.isEmpty ? 'Done' : 'Not now',
          onPressed: widget.onClose,
        ),
      ],
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.request,
    required this.granted,
    required this.onGrant,
  });

  final FolderRequest request;
  final bool granted;
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            granted ? LucideIcons.checkCheck : LucideIcons.folderLock,
            size: 15,
            color: granted ? CcColors.success : CcColors.textTertiary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.folder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.style(size: 12, color: CcColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  granted ? 'Access granted' : 'Needed ${request.reason}',
                  style: CcType.style(size: 11, color: CcColors.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (!granted) CcButton(label: 'Grant…', onPressed: onGrant),
        ],
      ),
    );
  }
}
