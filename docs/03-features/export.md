# Feature Spec — Export & Render Queue

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-21
> Requirements prefix: **EXP** · Pipeline: `01-architecture.md` §8

## Summary

Export is a background queue, not a modal prison. Presets match where creators publish; the default path (MP4/H.264/AAC, quality slider) covers 90% of jobs. Preview and export share one render pipeline, so output matches the program monitor by construction.

## User stories

- As Dev, I queue three verticals and keep editing while they render.
- As Maya, I pick "YouTube 1080p" and never think about bitrates.
- As Sam, I need a ProRes master of my demo for an agency handoff.

## Functional requirements

### Range & scope
- **EXP-1** Range options: Entire sequence (default), In/Out range (if set), Selected clips duration? — no: Entire / In-Out only (v1).
- **EXP-2** Export renders from the **document snapshot at submit time**; later edits don't affect queued jobs (toast notes this once).

### Presets
| Preset | Container | Video | Audio | Notes |
|---|---|---|---|---|
| YouTube 1080p | MP4 | H.264 CRF 18, high profile | AAC 320 kbps | faststart |
| YouTube 4K | MP4 | H.264 CRF 20 (or HEVC toggle) | AAC 320 kbps | |
| Shorts/TikTok/Reels | MP4 | H.264 CRF 19, 1080×1920 | AAC 320 kbps | uses sequence orientation |
| Instagram Feed | MP4 | H.264 CRF 19, 1080×1350 max | AAC 320 kbps | letterbox/crop choice if aspect differs |
| Master (ProRes) | MOV | ProRes 422 Standard | PCM 24-bit | for handoff |
| Custom | user | codec/bitrate/resolution controls | | saved as user preset |

- **EXP-3** Resolution scaling: presets may scale sequence output (fit, aspect preserved); fps always = sequence fps (no retiming on export v1).
- **EXP-4** Quality model: single "Quality" slider (Draft → Web → High → Master) mapping to codec knobs (CRF/preset) per codec; advanced panel exposes raw CRF/bitrate/preset for experts (progressive disclosure).

### Codecs & hardware
- **EXP-5** Software encoders default: x264 (main), x265 optional, ProRes 422. Audio: AAC LC 320 kbps default; PCM WAV option in Master.
- **EXP-6** Hardware encoders opt-in per job ("Use hardware encoding" checkbox, remembered): VideoToolbox (macOS), NVENC/QSV/AMF (Windows). Tooltip: "Faster, slightly larger files at same quality".
- **EXP-7** Loudness normalization checkbox (default on for social presets): two-pass loudnorm to −14 LUFS, true peak −1.5 dBTP (AUD-12).

### Queue & lifecycle
- **EXP-8** Export dialog shows: preset picker, filename/location (default `<project name> [<preset>].mp4` to last-used or Movies folder), estimated size after first pass estimate, summary line.
- **EXP-9** Jobs enter a queue panel (toolbar icon with progress ring); multiple jobs run sequentially (configurable parallelism 1–2); each job: progress %, processed/total frames, fps, ETA, cancel button.
- **EXP-10** Editing continues during export; heavy UI ops remain responsive (worker process isolation). If the user edits the same project, preview performance may dip — acceptable, documented.
- **EXP-11** Completion actions per job: reveal in folder (default), open file, copy path. Failure: retry once automatically; then fail state with last log lines + "Copy diagnostics".
- **EXP-12** App quit with active jobs: confirm dialog listing jobs; cancel-and-quit or minimize-to-tray equivalent (macOS: keep running; Windows: tray icon) — v1 keeps it simple: confirm cancel.

### Integrity
- **EXP-13** Partial outputs write to `<name>.part` and rename atomically on success; failed jobs clean up partials.
- **EXP-14** Every job writes a sidecar `.log.json` (settings, timings, encoder) next to output on completion/failure.

## UX notes

- The export dialog previews final framing (letterbox/crop result) when preset aspect ≠ sequence aspect.
- Estimated file size appears within ~2 s via first-pass sample encode (top/middle/tail sampling), labeled "estimate".
- Queue lives in a slide-over panel; OS notification on completion (opt-in).

## Edge cases

- Zero-length range / empty sequence: export disabled with reason.
- Offline media at submit: dialog lists offline clips; choose Cancel or "Export with slates" (explicit).
- Disk full mid-write: job fails cleanly, partial removed, message names the volume.
- Sleep/hibernate: OS sleep prevented during active jobs (platform API) with Settings override.
- Target filename exists: auto-suffix ` (1)` — never silent overwrite.

## Acceptance criteria

1. Default preset export of the sample project: plays correctly in QuickTime/VLC/Chrome; A/V sync drift < 20 ms over 10 min test clip; faststart flag verified.
2. Queue 3 jobs, continue editing: UI stays ≥ 50 fps interactions; all 3 complete matching snapshot-at-submit content (regression test with scripted edit-during-export).
3. Cancel mid-job leaves zero partial files.
4. ProRes master opens in Resolve with correct duration ±1 frame and full-range video levels documented.

## Out of scope (v1)

Direct upload to YouTube/TikTok [v1.5 candidate], image-sequence export, GIF export, per-clip render/cache, distributed/network rendering, watermarking tools, HDR delivery.

## Changelog

- v0.1 — Initial draft.
