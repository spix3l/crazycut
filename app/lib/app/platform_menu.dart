import 'dart:async';

import 'package:file_selector/file_selector.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/widgets/cc_dialog.dart';
import '../state/editor_controller.dart';
import 'help_dialog.dart';
import 'router/app_router.dart';
import 'router/app_router.gr.dart';
import 'session.dart';

/// The macOS menu bar and everything it can trigger, kept apart from the app
/// root so root stays plumbing. Flutter draws no native menu bar on the other
/// platforms CrazyCut ships, so there the child passes through untouched.
class CrazyCutMenuBar extends StatelessWidget {
  const CrazyCutMenuBar({super.key, required this.router, required this.child});

  /// Must be the same instance the `WidgetsApp.router` was built with: menu
  /// actions navigate through it.
  final AppRouter router;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.macOS) return child;
    return PlatformMenuBar(menus: _menus, child: child);
  }

  bool get _hasProject => AppSession.instance.hasProject;

  EditorController? get _editor =>
      _hasProject ? AppSession.instance.editor : null;

  /// The root navigator's own Overlay, for menu actions that show a dialog.
  /// Menu callbacks only have the navigator's context, and `Overlay.of` can't
  /// resolve through it (the navigator's Overlay lives *below* it), so the
  /// overlay is handed to the dialog helpers directly.
  OverlayState? get _dialogOverlay => router.navigatorKey.currentState?.overlay;

  void _newProject() {
    router.push(const NewProjectRoute());
  }

  Future<void> _openProject() async {
    const types = [
      XTypeGroup(label: 'CrazyCut project', extensions: ['crazycut']),
    ];
    final file = await openFile(acceptedTypeGroups: types);
    if (file == null) return;
    await AppSession.instance.rememberProjectLocation(file.path);
    await AppSession.instance.openPath(file.path);
    router.replace(const EditorRoute());
  }

  void _closeProject() {
    if (!_hasProject) return;
    AppSession.instance.close().then(
      (_) => router.replace(const ProjectBrowserRoute()),
    );
  }

  void _save() {
    _editor?.saveNow();
  }

  Future<void> _saveAs() async {
    final editor = _editor;
    if (editor == null) return;
    final location = await getSaveLocation(
      suggestedName: '${editor.doc.name}.crazycut',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CrazyCut project', extensions: ['crazycut']),
      ],
    );
    if (location != null) await editor.saveCopy(location.path);
  }

  void _importMedia() {
    final editor = _editor;
    if (editor == null) return;
    _importMediaInto(editor);
  }

  Future<void> _importMediaInto(EditorController editor) async {
    const types = [
      XTypeGroup(
        label: 'Media',
        extensions: [
          'mp4',
          'mov',
          'mkv',
          'webm',
          'm4v',
          'wav',
          'mp3',
          'aac',
          'm4a',
          'flac',
          'ogg',
          'png',
          'jpg',
          'jpeg',
          'webp',
          'gif',
          'svg',
        ],
      ),
    ];
    final files = await openFiles(acceptedTypeGroups: types);
    if (files.isNotEmpty) {
      await editor.importPaths(files.map((file) => file.path).toList());
    }
  }

  Future<void> _importMediaUrl() async {
    final editor = _editor;
    final context = router.navigatorKey.currentContext;
    final overlay = _dialogOverlay;
    if (editor == null || context == null || overlay == null) return;
    final value = await promptForText(
      context,
      title: 'Add from URL',
      label: 'Direct media or YouTube URL',
      confirmLabel: 'Add',
      overlay: overlay,
    );
    if (value == null || value.isEmpty) return;
    try {
      await editor.importUrl(value);
    } on Object catch (error) {
      if (!context.mounted) return;
      await showMessageDialog(
        context,
        title: 'Couldn’t add URL',
        message: error.toString(),
        overlay: overlay,
      );
    }
  }

  /// Help ▸ CrazyCut Help.
  Future<void> _showHelp() async {
    final context = router.navigatorKey.currentContext;
    final overlay = _dialogOverlay;
    if (context == null || overlay == null) return;
    await showHelpDialog(context, overlay: overlay);
  }

  void _undo() => _editor?.undo();
  void _redo() => _editor?.redo();
  void _selectAll() => _editor?.selectAll();
  void _cut() => _editor?.cutSelection();
  void _copy() => _editor?.copySelection();
  void _paste() => unawaited(_pasteFromClipboard());

  /// Edit ▸ Paste, matching Cmd+V in the editor: media sitting on the system
  /// clipboard is imported (IMP-1), anything else pastes the copied clips.
  Future<void> _pasteFromClipboard() async {
    final editor = _editor;
    if (editor == null) return;
    final result = await editor.importFromClipboard(onlyIfNewerThanCopy: true);
    if (!result.handled) {
      editor.paste();
      return;
    }
    final context = router.navigatorKey.currentContext;
    final overlay = _dialogOverlay;
    if (result.error == null ||
        context == null ||
        overlay == null ||
        !context.mounted) {
      return;
    }
    await showMessageDialog(
      context,
      title: 'Couldn\u2019t paste',
      message: result.error!,
      overlay: overlay,
    );
  }

  void _pasteSettings() => _editor?.pasteAttributes();
  void _delete() => _editor?.deleteSelected();

  /// Arms or disarms the on-canvas region tool (**TRK-1**). Reachable from the
  /// menu bar as well as the inspector's Track tab, because a drawing tool is
  /// something you reach for while looking at the picture, not at a panel.
  void _toggleTrackTool() {
    final editor = _editor;
    if (editor == null) return;
    editor.trackToolActive = !editor.trackToolActive;
  }

  void _togglePlay() => _editor?.togglePlay();
  void _goToStart() => _editor?.goToStart();
  void _goToEnd() => _editor?.goToEnd();

  List<PlatformMenuItem> get _menus => [
    PlatformMenu(
      label: 'CrazyCut',
      menus: [
        if (PlatformProvidedMenuItem.hasMenu(
          PlatformProvidedMenuItemType.about,
        ))
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.about,
          ),
        PlatformMenuItem(
          label: 'Preferences…',
          shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
          onSelected: () => router.push(const SettingsRoute()),
        ),
        if (PlatformProvidedMenuItem.hasMenu(
          PlatformProvidedMenuItemType.servicesSubmenu,
        ))
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.servicesSubmenu,
          ),
        if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.hide))
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.hide,
          ),
        if (PlatformProvidedMenuItem.hasMenu(
          PlatformProvidedMenuItemType.hideOtherApplications,
        ))
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.hideOtherApplications,
          ),
        if (PlatformProvidedMenuItem.hasMenu(
          PlatformProvidedMenuItemType.showAllApplications,
        ))
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.showAllApplications,
          ),
        if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.quit))
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.quit,
          ),
      ],
    ),
    PlatformMenu(
      label: 'File',
      menus: [
        PlatformMenuItem(
          label: 'New Project',
          shortcut: const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
          onSelected: _newProject,
        ),
        PlatformMenuItem(
          label: 'Open Project…',
          shortcut: const SingleActivator(LogicalKeyboardKey.keyO, meta: true),
          onSelected: _openProject,
        ),
        PlatformMenuItem(
          label: 'Import Media…',
          shortcut: const SingleActivator(LogicalKeyboardKey.keyI, meta: true),
          onSelected: _importMedia,
        ),
        PlatformMenuItem(
          label: 'Import from URL…',
          onSelected: _importMediaUrl,
        ),
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: 'Close Project',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyW,
                meta: true,
              ),
              onSelected: _closeProject,
            ),
          ],
        ),
        PlatformMenuItem(
          label: 'Save',
          shortcut: const SingleActivator(LogicalKeyboardKey.keyS, meta: true),
          onSelected: _save,
        ),
        PlatformMenuItem(
          label: 'Save As…',
          shortcut: const SingleActivator(
            LogicalKeyboardKey.keyS,
            meta: true,
            shift: true,
          ),
          onSelected: _saveAs,
        ),
      ],
    ),
    PlatformMenu(
      label: 'Edit',
      menus: [
        PlatformMenuItem(
          label: 'Undo',
          shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
          onSelected: _undo,
        ),
        PlatformMenuItem(
          label: 'Redo',
          shortcut: const SingleActivator(
            LogicalKeyboardKey.keyZ,
            meta: true,
            shift: true,
          ),
          onSelected: _redo,
        ),
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: 'Cut',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyX,
                meta: true,
              ),
              onSelected: _cut,
            ),
            PlatformMenuItem(
              label: 'Copy',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyC,
                meta: true,
              ),
              onSelected: _copy,
            ),
            PlatformMenuItem(
              label: 'Paste',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyV,
                meta: true,
              ),
              onSelected: _paste,
            ),
            PlatformMenuItem(
              label: 'Paste Settings',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyV,
                meta: true,
                alt: true,
              ),
              onSelected: _pasteSettings,
            ),
            PlatformMenuItem(
              label: 'Delete',
              shortcut: const SingleActivator(LogicalKeyboardKey.backspace),
              onSelected: _delete,
            ),
            PlatformMenuItem(
              label: 'Select All',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyA,
                meta: true,
              ),
              onSelected: _selectAll,
            ),
          ],
        ),
      ],
    ),
    PlatformMenu(
      label: 'Clip',
      menus: [
        // A static label that toggles, rather than one reading "Stop…" while
        // armed: the menu bar does not listen to the editor, so a stateful
        // label would sit there stale and lie about what the item does.
        PlatformMenuItem(
          label: 'Track Region',
          shortcut: const SingleActivator(
            LogicalKeyboardKey.keyT,
            meta: true,
            shift: true,
          ),
          onSelected: _toggleTrackTool,
        ),
      ],
    ),
    PlatformMenu(
      label: 'Playback',
      menus: [
        PlatformMenuItem(
          label: 'Play / Pause',
          shortcut: const SingleActivator(LogicalKeyboardKey.space),
          onSelected: _togglePlay,
        ),
        PlatformMenuItem(
          label: 'Go to Start',
          shortcut: const SingleActivator(LogicalKeyboardKey.home),
          onSelected: _goToStart,
        ),
        PlatformMenuItem(
          label: 'Go to End',
          shortcut: const SingleActivator(LogicalKeyboardKey.end),
          onSelected: _goToEnd,
        ),
      ],
    ),
    PlatformMenu(
      label: 'View',
      menus: [
        if (PlatformProvidedMenuItem.hasMenu(
          PlatformProvidedMenuItemType.toggleFullScreen,
        ))
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.toggleFullScreen,
          ),
      ],
    ),
    PlatformMenu(
      label: 'Window',
      menus: [
        if (PlatformProvidedMenuItem.hasMenu(
          PlatformProvidedMenuItemType.minimizeWindow,
        ))
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.minimizeWindow,
          ),
        if (PlatformProvidedMenuItem.hasMenu(
          PlatformProvidedMenuItemType.zoomWindow,
        ))
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.zoomWindow,
          ),
        if (PlatformProvidedMenuItem.hasMenu(
          PlatformProvidedMenuItemType.arrangeWindowsInFront,
        ))
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.arrangeWindowsInFront,
          ),
      ],
    ),
    PlatformMenu(
      label: 'Help',
      menus: [
        // ⇧⌘/ is macOS's standard Help shortcut (what the menu renders as ⌘?).
        PlatformMenuItem(
          label: 'CrazyCut Help',
          shortcut: const SingleActivator(
            LogicalKeyboardKey.slash,
            meta: true,
            shift: true,
          ),
          onSelected: _showHelp,
        ),
      ],
    ),
  ];
}
