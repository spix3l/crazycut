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
- **IMP-1** Import via: drag-drop onto media pool *or* timeline *or* preview; File → Import dialog (multi-select); paste (Cmd/Ctrl+V anywhere in the editor, or Edit ▸ Paste).
  - A paste takes whatever the system clipboard holds: files copied in a file manager, a raw bitmap (a screenshot, an image copied out of a browser), a `file://` URL or a path copied as text, or a media URL — which lands on the same path as IMP-1a, YouTube links included.
  - A bitmap has no file behind it and the project stores paths, not pixels, so the bytes are written into `<project>/Media/` as `Pasted image.png` (numbered on collision) before the asset exists. That is where PRJ-14's collect would have put it, so the project folder stays self-contained. Pasting the same bitmap twice deduplicates by hash per IMP-3 and the redundant copy is deleted rather than left behind.
  - A paste is a placement, not a filing action: pasted media lands on the timeline at the playhead in clipboard order, pushing what sat there to the right, and the playhead stays put — the same shape as the timeline's own paste. A YouTube link is a reference (IMP-1b) and so is only filed, never placed. Pasting is implicit: there is no paste affordance in the pool, because the keystroke is the affordance.
  - Cmd/Ctrl+V is also the timeline's paste (TIM-17), and that paste keeps the keystroke unless media demonstrably arrived after the copy: the host's clipboard generation must be known, the mark taken at copy time must have landed, and the two must differ. Text never qualifies however new it is, since a URL is the likeliest thing to be left lying on a clipboard. Anything less certain pastes the clips — a clip paste that silently turned into an import is the worse failure, and it is the one that has to be impossible. With nothing copied in the app, Cmd/Ctrl+V takes everything the clipboard offers, URLs included.
  - Where a platform has no host channel, paste degrades to plain text, which still covers pasting a media URL.
- **IMP-1a** Add a public direct HTTP(S) URL for supported video, audio, or image media. The URL remains the project source; thumbnails, waveforms, SVG rasters, transcripts, and proxies remain disposable derived cache files.
- **IMP-1b** YouTube page links are stored as viewing-only references using the official embedded player. They cannot be placed on the timeline, decoded, proxied, transcribed, collected, or exported.
- **IMP-1c** A URL source is mirrored into the media cache in the background on import and after a revalidation that changed its bytes; preview, filmstrips, proxies and export decode from that copy, falling back to streaming from the URL while it is downloading, when the source exceeds the 512 MB mirror limit, or when the download fails. Streaming can only decode forwards — a seek re-opens the connection, and a format without a keyframe index (GIF above all) must re-read from byte 0 — so a mirrored copy is what makes scrubbing, looping and playback of URL clips behave like local media.
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
- **IMP-18** URL assets are revalidated on import, project open, manual refresh, and export. Changed response validators invalidate derivatives; unreachable sources show a retryable *remote unavailable* state rather than a local relink prompt.

## UX notes

- Import progress is a single non-modal pill (bottom-left): "Preparing 12 files… 4 done" expanding to a task list on click. Individual failures are rows there, not popups.
- Drag-drop affordance: dropping onto the timeline at a position shows a ghost clip + insertion line before release (with track targeting rules from `03-features/timeline.md`).
- Pool cards scale with zoom slider; filmstrip thumbs animate under the playhead when scrubbing over a clip (timeline rendering detail in TIM spec).

## Edge cases

- Importing while exporting/proxying: IO pool prioritizes interactive probes; proxies yield.
- Same file imported while already hashing: jobs coalesce.
- The same normalized URL selects the existing asset. Query parameter order is preserved because signed/CDN URLs may treat it as significant.
- Cache mirrors are disposable: clearing the media cache (or a changed ETag/Last-Modified) drops them, and the next import/open/refresh downloads again.
- Collect media explicitly downloads URL-backed originals, atomically repoints them to the collected files, and leaves YouTube references remote.
- Files on removable drives that vanish mid-session: active decoders fail gracefully → affected clips show offline slates; relink flow available immediately.
- Extremely long filenames / unicode: preserved verbatim; display truncates middle.
- 4K60 H.264 10-bit on Intel iGPU Mac: hw decode unavailable → software decode + automatic proxy keeps preview realtime.

## Acceptance criteria

1. Drop a mixed folder (H.264/H.265/images/audio) → all supported items appear in pool within 2 s each (probe), thumbnails stream in, zero blocking dialogs.
2. iPhone HEVC vertical plays upright with correct duration ±1 frame vs QuickTime.
3. Rename/move source file → reopen → Missing media panel relinks entire folder by hash in one action.
4. Removing a proxy regenerates on demand without user-visible failure.

## Out of scope (v1)

Watch folders, camera/card ingest with checksum verify, authenticated URL headers/cookies, extracting or downloading YouTube media, transcoding on import (other than proxies), bins/collections, ratings/flags/metadata tagging.

## Changelog

- v0.1 — Initial draft.
