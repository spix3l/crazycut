import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/design/tokens.dart';
import '../core/widgets/cc_dialog.dart';
import '../core/widgets/primitives.dart';

/// What Help ▸ CrazyCut Help opens: getting-started basics plus the full
/// keyboard map, mirroring `editor_screen.dart`'s key handler and the
/// File/Edit menu shortcuts.
Future<void> showHelpDialog(BuildContext context) {
  final completer = Completer<void>();
  final overlay = Overlay.of(context);
  late OverlayEntry entry;

  void finish() {
    if (completer.isCompleted) return;
    entry.remove();
    completer.complete();
  }

  entry = OverlayEntry(
    builder: (context) => Focus(
      autofocus: true,
      // The editor's key handler would otherwise consume Escape (it deselects
      // the clip). Holding focus here routes Escape to closing the dialog, and
      // focus falls back to the editor once the entry is removed.
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          finish();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: CcModalBarrier(
        onDismiss: finish,
        child: CcDialogShell(
          title: 'CrazyCut Help',
          width: 640,
          onClose: finish,
          sections: const [_GettingStarted(), _Shortcuts()],
          actions: [CcButton(label: 'Close', onPressed: finish)],
        ),
      ),
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _GettingStarted extends StatelessWidget {
  const _GettingStarted();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: CcColors.elevated, borderRadius: CcRadius.brMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Getting started', style: CcType.bodyStrong),
          const SizedBox(height: 6),
          Text(
            'Drag media files onto the window — or File ▸ Import Media (⌘I) — and '
            'drag the imported clips onto the timeline to arrange your cut. '
            'Space plays, S splits the clip under the playhead, M drops a marker, '
            'and ⌘E opens the export.',
            style: CcType.style(
              size: 13,
              color: CcColors.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// One row of the shortcut reference: what it does, and the key combo.
typedef _ShortcutEntry = (String action, String keys);

class _Shortcuts extends StatelessWidget {
  const _Shortcuts();

  static const _playback = <_ShortcutEntry>[
    ('Play / pause', 'Space'),
    ('Shuttle backward / stop / forward', 'J  K  L'),
    ('Step one frame', '←  →'),
    ('Seek one second', '⇧←  ⇧→'),
    ('Previous / next marker', '↑  ↓'),
    ('Go to start / end', 'Home  End'),
    ('Previous / next clip edge', 'PgUp  PgDn'),
  ];

  static const _editing = <_ShortcutEntry>[
    ('Split at playhead', 'S'),
    ('Add marker', 'M'),
    ('Set in / out', 'I  O'),
    ('Clear in & out', '⌥X'),
    ('Duplicate selection', '⌘D'),
    ('Select all clips', '⌘A'),
    ('Delete selection', '⌫'),
    ('Ripple delete', '⇧⌫'),
    ('Deselect / leave fullscreen', 'Esc'),
  ];

  static const _clipboard = <_ShortcutEntry>[
    ('Cut', '⌘X'),
    ('Copy', '⌘C'),
    ('Paste', '⌘V'),
    ('Paste settings', '⌘⌥V'),
  ];

  static const _project = <_ShortcutEntry>[
    ('New project', '⌘N'),
    ('Open project', '⌘O'),
    ('Import media', '⌘I'),
    ('Save project', '⌘S'),
    ('Save project as…', '⇧⌘S'),
    ('Close project', '⌘W'),
    ('Export…', '⌘E'),
    ('Save as template', '⇧⌘T'),
    ('Preferences…', '⌘,'),
  ];

  static const _view = <_ShortcutEntry>[
    ('Preview fullscreen', 'F'),
    ('Zoom timeline in / out', '⌘=  ⌘−'),
    ('Zoom timeline to fit', '\\'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Keyboard shortcuts', style: CcType.bodyStrong),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ShortcutGroup('Playback', _playback),
                  const SizedBox(height: 18),
                  _ShortcutGroup('Editing', _editing),
                ],
              ),
            ),
            const SizedBox(width: 28),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ShortcutGroup('Clipboard', _clipboard),
                  const SizedBox(height: 18),
                  _ShortcutGroup('Project', _project),
                  const SizedBox(height: 18),
                  _ShortcutGroup('View', _view),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ShortcutGroup extends StatelessWidget {
  const _ShortcutGroup(this.title, this.entries);

  final String title;
  final List<_ShortcutEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.toUpperCase(), style: CcType.sectionHeader),
        const SizedBox(height: 4),
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    entry.$1,
                    style: CcType.style(
                      size: 12,
                      color: CcColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  entry.$2,
                  style: CcType.style(size: 12, weight: CcType.semibold),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
