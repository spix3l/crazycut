// Update dialogs: manual check flow and the ready-to-install prompt.
//
// All entry points accept the optional navigator-level overlay used by menu
// actions (see `CcDialogShell` callers). Release notes render as truncated
// plain text, never Markdown, and the only tappable link is the validated
// release page URL opened in a browser.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:crazycut_app/app/dependencies.dart';
import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/cc_dialog.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';

import '../application/update_service.dart';
import '../application/update_status.dart';
import '../domain/update_release.dart';

String formatUpdateBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

int _assetSize(UpdateRelease release) {
  if (Platform.isMacOS) return release.macos.size;
  if (Platform.isWindows) return release.windows.size;
  return 0;
}

String _installSteps(UpdateRelease release) {
  if (Platform.isMacOS) {
    return '1. Quit CrazyCut completely.\n'
        '2. Open the DMG and drag CrazyCut into Applications, replacing '
        'the old copy.\n'
        '3. Relaunch from Applications (do not run from the DMG).\n'
        'Gatekeeper verifies the app on first launch.';
  }
  if (Platform.isWindows) {
    return '1. Quit CrazyCut completely (the running files are locked).\n'
        '2. Unzip the downloaded file over the install location.\n'
        '3. Relaunch. SmartScreen may warn because this build is '
        'unsigned: do not disable SmartScreen, cancel if anything '
        'looks unexpected.';
  }
  return 'Install the downloaded file manually, then relaunch.';
}

/// Manual "Check for Updates" flow: checking spinner, live download
/// progress, up-to-date confirmation, or one friendly error.
Future<void> showManualUpdateCheck(
  BuildContext context, {
  OverlayState? overlay,
}) {
  final service = AppDependenciesScope.read(context).updates;
  final completer = Completer<void>();
  final host = overlay ?? Overlay.of(context);
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
          child: ListenableBuilder(
            listenable: service,
            builder: (context, _) {
              return CcDialogShell(
                title: 'Software Update',
                width: 480,
                onClose: finish,
                sections: [_ManualBody(service: service)],
                actions: _manualActions(service, finish),
              );
            },
          ),
        ),
  );
  host.insert(entry);
  // ignore: discarded_futures
  service.checkNow(userInitiated: true).catchError((Object _) {});
  return completer.future;
}

class _ManualBody extends StatelessWidget {
  const _ManualBody({required this.service});

  final UpdateService service;

  @override
  Widget build(BuildContext context) {
    switch (service.status) {
      case UpdateStatus.checking:
      case UpdateStatus.idle:
        return Text(
          'Checking for updates…',
          style: CcType.style(
            size: 13,
            color: CcColors.textSecondary,
            height: 1.5,
          ),
        );
      case UpdateStatus.upToDate:
        return Text(
          'CrazyCut is up to date.',
          style: CcType.style(
            size: 13,
            color: CcColors.textSecondary,
            height: 1.5,
          ),
        );
      case UpdateStatus.error:
        return Text(
          service.errorMessage.isEmpty
              ? 'The update check failed.'
              : service.errorMessage,
          style: CcType.style(size: 13, color: CcColors.error, height: 1.5),
        );
      case UpdateStatus.available:
      case UpdateStatus.downloading:
        final release = service.release;
        final size =
            release == null ? '' : formatUpdateBytes(_assetSize(release));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              release == null
                  ? 'Downloading update…'
                  : 'Downloading ${release.tag} ($size)…',
              style: CcType.bodyStrong,
            ),
            const SizedBox(height: 10),
            _ProgressBar(value: service.progress),
            const SizedBox(height: 8),
            Text(
              '${(service.progress * 100).round()}% · verified after '
              'download, the current install stays untouched until then.',
              style: CcType.style(
                size: 11,
                color: CcColors.textTertiary,
                height: 1.4,
              ),
            ),
          ],
        );
      case UpdateStatus.ready:
        return _ReadyBody(service: service);
    }
  }
}

List<Widget> _manualActions(UpdateService service, VoidCallback finish) {
  switch (service.status) {
    case UpdateStatus.checking:
    case UpdateStatus.idle:
      return [CcButton(label: 'Cancel', onPressed: finish)];
    case UpdateStatus.upToDate:
    case UpdateStatus.error:
      return [
        if (service.release != null)
          CcButton(
            label: 'Retry',
            kind: CcButtonKind.secondary,
            onPressed: () {
              // ignore: discarded_futures
              service.downloadRelease();
            },
          ),
        CcButton(label: 'Close', onPressed: finish),
      ];
    case UpdateStatus.available:
    case UpdateStatus.downloading:
      return [
        CcButton(
          label: 'Cancel download',
          kind: CcButtonKind.secondary,
          onPressed: () => service.cancelDownload(),
        ),
      ];
    case UpdateStatus.ready:
      return _readyActions(service, finish);
  }
}

/// Ready-to-install prompt, also shown once after a background download.
Future<void> showUpdateReadyDialog(
  BuildContext context,
  UpdateService service, {
  OverlayState? overlay,
}) {
  final completer = Completer<void>();
  final host = overlay ?? Overlay.of(context);
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
          child: ListenableBuilder(
            listenable: service,
            builder:
                (context, _) => CcDialogShell(
                  title: 'Update ready to install',
                  width: 480,
                  onClose: finish,
                  sections: [_ReadyBody(service: service)],
                  actions: _readyActions(service, finish),
                ),
          ),
        ),
  );
  host.insert(entry);
  return completer.future;
}

class _ReadyBody extends StatelessWidget {
  const _ReadyBody({required this.service});

  final UpdateService service;

  @override
  Widget build(BuildContext context) {
    final release = service.release;
    if (release == null) {
      return Text(
        'The update downloaded.',
        style: CcType.style(
          size: 13,
          color: CcColors.textSecondary,
          height: 1.5,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${release.tag} downloaded and verified.',
          style: CcType.bodyStrong,
        ),
        const SizedBox(height: 8),
        Text(
          _installSteps(release),
          style: CcType.style(
            size: 12,
            color: CcColors.textSecondary,
            height: 1.5,
          ),
        ),
        if (release.notes.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text("What is new", style: CcType.bodyStrong),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CcColors.elevated,
              borderRadius: CcRadius.brMd,
            ),
            child: Text(
              release.notes,
              style: CcType.style(
                size: 12,
                color: CcColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'SHA-256: ${service.release == null ? '' : _shortSha(service)}… '
          '(full hash verified against the signed manifest)',
          style: CcType.style(
            size: 11,
            color: CcColors.textTertiary,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  String _shortSha(UpdateService service) {
    final r = service.release;
    if (r == null) return '';
    final full = Platform.isMacOS ? r.macos.sha256 : r.windows.sha256;
    return full.length > 12 ? full.substring(0, 12) : full;
  }
}

List<Widget> _readyActions(UpdateService service, VoidCallback finish) {
  return [
    CcButton(
      label: 'Skip this version',
      kind: CcButtonKind.ghost,
      onPressed: () {
        service.dismissVersion();
        finish();
      },
    ),
    CcButton(
      label: 'Show file',
      kind: CcButtonKind.secondary,
      onPressed: () {
        // ignore: discarded_futures
        _revealDownload(service);
      },
    ),
    CcButton(label: 'Later', onPressed: finish),
  ];
}

Future<void> _revealDownload(UpdateService service) async {
  final path = service.downloadedPath;
  if (path.isEmpty) return;
  final dir = File(path).parent.path;
  try {
    await launchUrl(Uri.file(dir));
  } on Object {
    // Revealing is best effort; the path is shown in the dialog body.
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);
    return Container(
      height: 8,
      decoration: BoxDecoration(
        color: CcColors.elevated2,
        borderRadius: CcRadius.brMd,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: clamped == 0 ? 0.02 : clamped,
          child: Container(
            decoration: BoxDecoration(
              color: CcColors.accent,
              borderRadius: CcRadius.brMd,
            ),
          ),
        ),
      ),
    );
  }
}
