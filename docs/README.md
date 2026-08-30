# CrazyCut — Documentation Index

> Status: Draft v0.1 · Last updated: 2026-08-21

CrazyCut is a native desktop video editor for solo creators: Flutter UI + C++ engine (FFI) + ffmpeg. Simple like Canva, capable like an NLE. MIT licensed.

## Reading order

| # | Doc | What it covers |
|---|---|---|
| 0 | [`00-product-overview.md`](00-product-overview.md) | Vision, personas, goals/non-goals, competitive position, success metrics |
| 1 | [`01-architecture.md`](01-architecture.md) | System design: process/thread model, FFI boundary, playback & render pipelines, export worker, licensing, perf budgets |
| 2 | [`02-data-model.md`](02-data-model.md) | `.crazycut` project format, entities, rational time, keyframe encoding, autosave/recovery, migrations |
| 3 | [`03-features/projects.md`](03-features/projects.md) | Project browser, creation presets, autosave/backups, settings (**PRJ**) |
| 3 | [`03-features/media-import.md`](03-features/media-import.md) | Import paths, probing, thumbnails/waveforms/proxies, relink (**IMP**) |
| 3 | [`03-features/timeline.md`](03-features/timeline.md) | Multi-track editing, trimming, snapping, JKL, undo (**TIM**) |
| 3 | [`03-features/effects.md`](03-features/effects.md) | Color/blur/transform/blend effect stacks (**FX**) |
| 3 | [`03-features/transitions.md`](03-features/transitions.md) | Transition catalog + handle-consumption placement rules (**TRA**) |
| 3 | [`03-features/text-keyframes.md`](03-features/text-keyframes.md) | Text clips, presets/animations, shared keyframe system (**TXT**/**KEY**) |
| 3 | [`03-features/captions.md`](03-features/captions.md) | Transcript conversion, caption editing, styling, render and sidecars (**CAP**) |
| 3 | [`03-features/audio.md`](03-features/audio.md) | Gain/fades/detach/mixer/loudness (**AUD**) |
| 3 | [`03-features/templates.md`](03-features/templates.md) | Reusable timeline chunks with slots and edge transitions (**TPL**) |
| 3 | [`03-features/export.md`](03-features/export.md) | Presets, queue, hardware encoders, integrity (**EXP**) |
| 3 | [`03-features/ai-assist.md`](03-features/ai-assist.md) | Local transcription, vendor-neutral LLM providers, agent loop (**AI**) |
| 3 | [`03-features/shorts.md`](03-features/shorts.md) | Model-proposed short moments reviewed into 9:16 projects (**SHT**) |
| 3 | [`03-features/tracking.md`](03-features/tracking.md) | Region tracking and pinning an asset to the solved path (**TRK**) |
| 4 | [`04-ui-ux.md`](04-ui-ux.md) | Design principles, layout, panels, shortcuts, theming, a11y (**UIX**) |
| 5 | [`05-roadmap.md`](05-roadmap.md) | Milestones M0–M5, testing strategy, risk register |
| 6 | [`06-implementation-plan.md`](06-implementation-plan.md) | Dependency-aware creator-ready v1 plan and agent-sized assignments |
| 7 | [`07-capability-matrix.md`](07-capability-matrix.md) | Honest implemented/partial/missing status with verification boundaries |

## Conventions

- **Requirement ids** (`PRJ-1`, `TIM-4`, …) are stable and testable; acceptance criteria reference them. New requirements append, never renumber.
- **Status header** on every doc: `Draft vX.Y · Owner · Last updated`. Changes bump the version and add a Changelog entry.
- **Spec change process (RFC-lite):** propose edits in a PR touching only `docs/`; note impacted requirement ids; milestone gates in `05-roadmap.md` cite ids, so scope changes are explicit.
- **Non-goals are law:** anything listed under "Out of scope" or in `00-product-overview.md` §5 needs a spec amendment before implementation.

## Key decisions at a glance

| Decision | Choice | Where |
|---|---|---|
| Platforms | macOS 13+, Windows 10/11 x64 (Linux best-effort) | 00 §9 |
| Stack | Flutter + C++17 core via FFI + ffmpeg libs | 01 §1 |
| Rendering | One deterministic render graph for preview & export; GPU-first (Metal/D3D11), CPU fallback | 01 §7 |
| Export | Child-process worker, background queue | 01 §8 |
| Timeline | Multi-track NLE, free positioning + snapping, transitions consume handles | TIM / TRA |
| Project format | Local JSON `.crazycut`, rational time, media by SHA-256 hash | 02 |
| License | MIT app + GPL ffmpeg binaries (x264/x265), LGPL escape hatch documented | 01 §14 |
| Perf targets | Seek ≤100 ms p95 · 1080p realtime preview · export ≥1× realtime | 01 §12 |
