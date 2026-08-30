# Project instructions

## Writing style

Never use the em dash character (`—`) anywhere: not in UI-facing strings, not
in comments, not in docs, not in commit messages, not in conversation. Use
commas, colons, periods, or parentheses instead.

## App conventions worth keeping

- The macOS platform menu lives in `app/lib/app/platform_menu.dart`
  (`CrazyCutMenuBar`), not in `app.dart`. The app root stays plumbing only.
- Dialog helpers in `app/lib/core/widgets/cc_dialog.dart` and
  `app/lib/app/help_dialog.dart` take an optional `OverlayState? overlay` for
  callers that sit above the navigator (menu items), because `Overlay.of`
  cannot resolve through the navigator's own context.
