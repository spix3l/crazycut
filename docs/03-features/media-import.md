# Feature Spec — Media Import & Library

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-21
> Requirements prefix: **IMP** · Pipeline details: `01-architecture.md` §5

## Summary

Importing rushes must feel instant: drag files (or folders) anywhere, keep working while probing/thumbnails/waveforms/proxies happen in the background. The media pool shows everything with honest state (ready / preparing / offline).

## User stories

- As Maya, I dump a 40 GB folder of rushes and start cutting the first clip seconds later.
- As Dev, my iPhone verticals appear upright with sound, even though they're H.265 VFR.
- As Sam, when I move my footage drive, CrazyCut helps me relink everything in one dialog.

## Functional requirements

### Import paths
- **IMP-1** Import via: drag-drop onto media pool *or* timeline *or* preview; File → Import dialog (multi-select); paste copied files (Cmd/Ctrl+V in pool).
- **IMP-2** Dropping a folder imports supported files recursively (flat view with folder column; no bin hierarchy in v1).
- **IMP-3** Duplicates by content hash are deduplicated: re-importing the same file selects the existing asset instead.
- **IMP-4** Unsupported files are skipped with a summary toast ("Skipped 2 unsupported files") listing names; never a modal per file.

### Supported formats (v1)
- Video containers: MP4, MOV, MKV, WebM, M4V. Codecs: H.264, H.265/HEVC, VP9, AV1 (decode availability per bundled ffmpeg build).
- Audio: MP3, AAC/M4A, WAV, FLAC, OGG.
- Images: PNG, JPEG, WebP, SVG (SVG is rasterized transparently for preview/export; the original remains the project source).
- Animated images: GIF (imported as a video-style visual clip with its encoded frame timing and one-cycle duration; loop metadata does not repeat the clip automatically).
- Out: image sequences, RAW/BRAW/ProRes RAW, MXF (v1.5 candidates), DRM content (never).

### Probing & preparation (background)
- **IMP-5** Probe (< 1.5 s/file budget) extracts metadata per `02-data-model.md`; rotation metadata is applied so phone footage displays upright everywhere.
- **IMP-6** Thumbnails: filmstrip generated progressively (first thumb < 2 s); pool cards show poster frame immediately after probe.
- **IMP-7** Waveform peaks computed for audio-bearing assets on first timeline use or pool preview.
- **IMP-8** Proxy generation triggers automatically per rules in `01-architecture.md` §5 (>1440p, >60 Mbps, HEVC/AV1, VFR). Pool shows a subtle "proxy ready" tick; playback auto-switches tiers. Proxies can be disabled globally (Settings) or per-asset (context menu).
- **IMP-9** HDR sources are flagged and tone-mapped to SDR for v1; asset card carries an HDR badge.
- **IMP-10** VFR sources are conformed to sequence fps (via proxy or decode-time resample); asset card shows "conformed 29.97".

### Media pool UI
- **IMP-11** Views: grid (default) / list. Columns (list): name, type, duration, resolution, codec, status. Search by name; sort by name/import order/duration.
- **IMP-12** Asset context menu: Preview, Insert at playhead, Reveal in folder, Generate proxy now, Remove from project (never deletes source file), Properties (probe data).
- **IMP-13** Double-click previews the asset in a pool player (with audio) without touching the timeline.
- **IMP-14** Usage indicator: assets used in the sequence show count of referencing clips; removing an asset in use requires confirmation listing affected clips (which become offline if forced).

### Relink & missing media
- **IMP-15** On open, unresolved assets enter *offline* state (checkerboard card). A "Missing media" panel lists them with: last path, hash, size.
- **IMP-16** Relink flow: point at a file/folder → match by SHA-256 (exact) then name+size (proposed, confirmed). Folder relink matches recursively and reports matched/unmatched counts.
- **IMP-17** Offline clips on the timeline render as slates with asset name; they keep all edits and come alive when relinked.

## UX notes

- Import progress is a single non-modal pill (bottom-left): "Preparing 12 files… 4 done" expanding to a task list on click. Individual failures are rows there, not popups.
- Drag-drop affordance: dropping onto the timeline at a position shows a ghost clip + insertion line before release (with track targeting rules from `03-features/timeline.md`).
- Pool cards scale with zoom slider; filmstrip thumbs animate under the playhead when scrubbing over a clip (timeline rendering detail in TIM spec).

## Edge cases

- Importing while exporting/proxying: IO pool prioritizes interactive probes; proxies yield.
- Same file imported while already hashing: jobs coalesce.
- Files on removable drives that vanish mid-session: active decoders fail gracefully → affected clips show offline slates; relink flow available immediately.
- Extremely long filenames / unicode: preserved verbatim; display truncates middle.
- 4K60 H.264 10-bit on Intel iGPU Mac: hw decode unavailable → software decode + automatic proxy keeps preview realtime.

## Acceptance criteria

1. Drop a mixed folder (H.264/H.265/images/audio) → all supported items appear in pool within 2 s each (probe), thumbnails stream in, zero blocking dialogs.
2. iPhone HEVC vertical plays upright with correct duration ±1 frame vs QuickTime.
3. Rename/move source file → reopen → Missing media panel relinks entire folder by hash in one action.
4. Removing a proxy regenerates on demand without user-visible failure.

## Out of scope (v1)

Watch folders, camera/card ingest with checksum verify, transcoding on import (other than proxies), bins/collections, ratings/flags/metadata tagging.

## Changelog

- v0.1 — Initial draft.
