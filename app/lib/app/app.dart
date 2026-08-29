import 'package:file_selector/file_selector.dart';

import 'package:crazycut_app/ai/ai_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/design/tokens.dart';
import '../core/widgets/cc_dialog.dart';
import '../state/editor_controller.dart';
import 'router/app_router.dart';
import 'router/app_router.gr.dart';
import 'session.dart';

/// Application root. Deliberately not a `MaterialApp`: CrazyCut ships its own
/// design system, so it only needs the plumbing `WidgetsApp` provides.
class CrazyCutApp extends StatefulWidget {
  const CrazyCutApp({super.key});

  @override
  State<CrazyCutApp> createState() => _CrazyCutAppState();
}

class _CrazyCutAppState extends State<CrazyCutApp> {
  final _router = AppRouter();

  @override
  void initState() {
    super.initState();
    // Read the AI configuration once at startup so the editor knows whether to
    // show any AI affordance at all (AI-1). A failure here leaves AI off,
    // which is exactly the behaviour we want.
    AiSettings.instance.load().whenComplete(() {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = WidgetsApp.router(
      title: 'CrazyCut',
      color: CcColors.accent,
      routerConfig: _router.config(),
      textStyle: CcType.base,
      debugShowCheckedModeBanner: false,
      builder:
          (context, child) => ColoredBox(
            color: CcColors.bg,
            child: child ?? const SizedBox.shrink(),
          ),
    );

    if (defaultTargetPlatform != TargetPlatform.macOS) return app;
    return PlatformMenuBar(menus: _menus, child: app);
  }

  bool get _hasProject => AppSession.instance.hasProject;

  EditorController? get _editor =>
      _hasProject ? AppSession.instance.editor : null;

  void _newProject() {
    _router.push(const NewProjectRoute());
  }

  Future<void> _openProject() async {
    const types = [
      XTypeGroup(label: 'CrazyCut project', extensions: ['crazycut']),
    ];
    final file = await openFile(acceptedTypeGroups: types);
    if (file == null) return;
    await AppSession.instance.openPath(file.path);
    _router.replace(const EditorRoute());
  }

  void _closeProject() {
    if (!_hasProject) return;
    AppSession.instance.close().then(
      (_) => _router.replace(const ProjectBrowserRoute()),
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
    final context = _router.navigatorKey.currentContext;
    if (editor == null || context == null) return;
    final value = await promptForText(
      context,
      title: 'Add from URL',
      label: 'Direct media or YouTube URL',
      confirmLabel: 'Add',
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
      );
    }
  }

  void _undo() => _editor?.undo();
  void _redo() => _editor?.redo();
  void _selectAll() => _editor?.selectAll();
  void _cut() => _editor?.cutSelection();
  void _copy() => _editor?.copySelection();
  void _paste() => _editor?.paste();
  void _pasteSettings() => _editor?.pasteAttributes();
  void _delete() => _editor?.deleteSelected();
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
          onSelected: () => _router.push(const SettingsRoute()),
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
      menus: [PlatformMenuItem(label: 'CrazyCut Help', onSelected: () {})],
    ),
  ];
}
