# Feature Spec — Projects Management

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-21
> Requirements prefix: **PRJ** · Format details: `02-data-model.md`

## Summary

The project browser is the launch surface: create, open, duplicate, and clean up projects with zero ceremony. Projects autosave continuously; crashes lose nothing meaningful.

## User stories

- As Dev, I open CrazyCut between classes and jump into yesterday's edit in under 5 seconds.
- As Maya, my laptop died mid-edit; reopening offers everything back exactly as it was.
- As Sam, I keep a 16:9 demo and a 9:16 teaser of the same content as separate projects without confusion.

## Functional requirements

### Project browser (launch screen)
- **PRJ-1** Browser shows cards: name, thumbnail (last rendered frame or preset color), duration, resolution/fps badge, last-opened time. Sort: last opened (default), name, created. Search by name.
- **PRJ-2** Actions per card / toolbar: New, Open, Duplicate, Rename (inline), Show in folder, Move to Trash (OS trash; confirm dialog), project settings.
- **PRJ-3** "New Project" opens a compact dialog:
  - Name (default "Untitled" + date).
  - Preset tiles: **YouTube 1920×1080 · 30/60fps**, **Shorts/TikTok/Reels 1080×1920 · 30/60**, **Square 1080×1080 · 30**, **Custom** (width/height/fps/sample rate).
  - Location (defaults to `Documents/CrazyCut`, remembered).
- **PRJ-4** Recent projects list (max 10) also available in-app via File → Open Recent.
- **PRJ-5** Opening a project shows the editor; opening is cancellable and shows progress for large projects (>1 s).

### Autosave & backups
- **PRJ-6** Autosave per `02-data-model.md` §8: debounced 2 s after each committed change + hard save every 30 s while dirty. Indicator in title bar: "Saved · just now" / "Saving…".
- **PRJ-7** Backup ring: every 5 min while dirty → `backups/<name>-<timestamp>.crazycut`, keep 20 per project (configurable count).
- **PRJ-8** Crash recovery: if the app exited uncleanly with unsaved-at-crash state differing from disk, launch offers: Restore autosave / Open last saved / Browse backups (diffable by modified time + thumbnail).
- **PRJ-9** Manual "Save a copy…" exports an independent `.crazycut` snapshot anywhere.

### Project settings
- **PRJ-10** Settings dialog (also at creation): width/height (locked presets + custom), fps (23.976/24/25/29.97/30/50/59.94/60/custom rational), audio sample rate (48 kHz fixed v1), background color.
- **PRJ-11** Changing fps/resolution on a project with clips requires confirmation; behavior: fps change re-times nothing (clip sequence times preserved — visual duration shifts), resolution change re-fits layout via transform defaults. A "Reset to recommended" hint appears when media ≠ sequence settings.
- **PRJ-12** v1 = one sequence per project (see `02-data-model.md` §4); UI never exposes multi-sequence concepts.

### Storage & portability
- **PRJ-13** Default project folder `Documents/CrazyCut`; user-changeable default location in Settings.
- **PRJ-14** "Collect media to project folder" action (File menu): copies referenced assets into `<project>/Media/`, rewrites paths relative → portable project (manual, explicit, with size preview).

## UX notes

- First launch: browser with one card — "New project" — plus optional "Try the sample project" (downloads ~40 MB sample media pack on demand; enables the <10-min-first-export metric path).
- Deleting a project moves only the `.crazycut` file (and its backups) to OS trash; media untouched.
- Title bar shows `Project — CrazyCut` and marks unsaved state subtly (autosave makes this mostly moot).

## Edge cases

- Two windows / double-open of same project: blocked with focus-existing-window behavior (single-instance per project file, lockfile).
- Read-only volume (e.g., opened from DMG): app opens read-only mode banner; editing disabled except "Save a copy…".
- Very long project names / reserved characters sanitized on save.
- Missing Documents permission (macOS TCC): prompt once, fall back to `~/Library/CrazyCut/Projects` gracefully.

## Acceptance criteria

1. Kill -9 during editing → relaunch → recovery chooser restores ≤ 30 s of work max (autosave cadence), zero corruption.
2. Create Shorts preset project → settings panel reflects 1080×1920@30; export preset defaults match orientation.
3. Duplicate creates an independent copy with new ids (editing one never affects the other).

## Out of scope (v1)

Cloud sync, team/collaboration, project templates gallery, version history UI beyond backup ring, multi-sequence projects.

## Changelog

- v0.1 — Initial draft.
