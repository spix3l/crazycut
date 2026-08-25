# CrazyCut — Technical Architecture

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-21
> Companion docs: `00-product-overview.md`, `02-data-model.md`

## 1. Overview

CrazyCut is a native desktop app: a **Flutter UI** for all interaction, and a **C++ engine** ("the core") that owns everything performance-critical — media probing, decoding, real-time compositing, audio mixing, and export encoding. The two talk over a narrow C ABI via `dart:ffi`. ffmpeg's libraries (`libavformat`, `libavcodec`, `libavfilter`, `libswscale`, `libswresample`) provide demux/decode/encode; GPU APIs (Metal / D3D11) accelerate compositing and effects.

```
┌──────────────────────────────────────────────────────────────┐
│                        CrazyCut.app                          │
│                                                              │
│  ┌────────────────────────┐        ┌───────────────────────┐ │
│  │      Flutter UI        │        │    Export worker      │ │
│  │  (Dart, main isolate)  │        │   (child process)     │ │
│  │  panels · timeline ·   │        │  offline render +     │ │
│  │  inspector · state     │        │  encode → output file │ │
│  └──────────┬─────────────┘        └──────────▲────────────┘ │
│             │ dart:ffi (C ABI)                │ stdin/stdout │
│  ┌──────────▼─────────────┐    spawn+submit   │ (JSON lines) │
│  │    Engine (C++17)      ├───────────────────┘              │
│  │  probe · decode ·      │                                  │
│  │  composite · mix       │                                  │
│  └──────────┬─────────────┘                                  │
│             │ external texture / pixel buffer                │
│  ┌──────────▼─────────────┐     ┌───────────────────────┐    │
│  │  GPU: Metal / D3D11    │     │ Audio device          │    │
│  │  (+ CPU SIMD fallback) │     │ (CoreAudio / WASAPI)  │    │
│  └────────────────────────┘     └───────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

### Core principles

1. **One render path.** Preview and export evaluate the same deterministic render graph. WYSIWYG is structural, not aspirational.
2. **The UI never blocks.** Every engine call is asynchronous from Dart's perspective; heavy work lives on engine threads.
3. **The document lives in Dart.** The project JSON document is owned and mutated by the app layer (command pattern). The engine holds only a *derived, disposable* render graph rebuilt from snapshots. The engine is restartable state.
4. **Crash isolation where it pays.** Export runs in a child process. A codec crash during export never takes down an edit session.
5. **GPU-first, CPU-correct.** Effects ship with a shader implementation and a CPU reference implementation used for fallback and golden-frame tests.

## 2. Process & threading model

| Process | Threads | Responsibility |
|---|---|---|
| Main (UI) | Flutter/Dart platform + UI + worker isolates | All UI, document model, undo stack, autosave |
| Main (engine, in-process) | **Render thread** (1) | Evaluate render graph per frame, present texture |
| | **Decode pool** (N = max(2, cores/2)) | Demux/decode video frames on demand |
| | **Audio callback** (RT thread) | Mix audio into device buffer, drives master clock |
| | **IO pool** (2) | Probing, thumbnails, waveform peaks, proxy transcodes |
| Export child | Render + decode pool + encoder thread | Offline render at target fps, encode, progress events |

Rules:

- The Dart side communicates via a **command queue**: calls enqueue work and return `Future`s completed by engine callbacks bridged to a `ReceivePort` (`NativeCallable.listener`).
- The audio callback is real-time: no locks, no allocations, no logging on that thread; it consumes pre-mixed ring buffers.
- Decode results land in a bounded frame cache (see §6); the render thread only ever consumes decoded textures/buffers, never demuxes.
- A watchdog monitors the render thread; if it misses deadlines catastrophically or asserts, the engine resets its graph and the UI shows a non-modal "recovering playback" toast. The document is untouched (it lives in Dart).

## 3. Component breakdown

### Engine (C++17), repo layout

```
engine/
  core/        time (rational), ids, result/error codes, log, serialization helpers
  model/       read-only snapshot types mirroring 02-data-model.md
  media/       probe, decoder sessions, thumbnailer, waveform peaks, proxy transcoder
  graph/       render graph: nodes, params, keyframe evaluation, topological eval
  render/      compositor; backends: metal/, d3d/, cpu/ ; effect kernels (shared HLSL→Metal source)
  audio/       mixer nodes, resampler (swresample), fades, device I/O (miniaudio)
  export/      offline renderer loop, encoder pipeline (x264/x265/prores, AAC), loudnorm
  bindings/    crazycut.h (stable C ABI), lifecycle, command dispatch, event callbacks
  ipc/         export-worker protocol (length-prefixed JSON over stdio)
app/
  lib/
    ui/        screens, panels, widgets (Flutter)
    state/     Riverpod stores, document controller, undo/redo commands
    engine/    ffigen-generated bindings + hand-written async wrappers, event bridge
    data/      project repository, autosave, backups, caches paths
```

Third-party (C++): ffmpeg libs (GPL build), miniaudio (MIT), fmt, spdlog, nlohmann/json, GoogleTest. Image decoding (PNG/JPEG/WebP) goes through libavformat/libavcodec to keep one path; SVG is out of scope v1.

Flutter packages (recommended): flutter_riverpod, freezed, ffigen, uuid, intl, desktop_drop, file_selector, window_manager, screen_retriever. Pinned in `app/pubspec.yaml`.

### Ownership boundaries

- **Dart owns:** project document, selection, undo stack, UI state, autosave files, settings.
- **Engine owns:** decoders, GPU resources, caches, audio device, export workers. All rebuildable from a document snapshot.
- Handoff: on every committed document change, the app serializes a **graph delta** (or full snapshot for large changes) to the engine; the engine diffs its render graph incrementally (node-level).

## 4. FFI boundary

- One stable header `engine/bindings/crazycut.h`; all Dart bindings generated with `ffigen`. No C++ types cross the ABI.
- Conventions:
  - Opaque handles (`cc_engine`, `cc_graph_token`) — never raw pointers in Dart.
  - All strings UTF-8, caller-specified length; returned strings owned by engine until next call on that handle.
  - Every function returns `cc_result` (int32 error code); detailed message fetched via `cc_last_error()`.
  - Structs are fixed-layout (`#pragma pack` asserted statically); time values are rational `{int64 num, int32 den}` pairs.
- Async: long operations (probe, thumbnail batch, proxy, export submit) return job ids; progress/results arrive as JSON events through a single registered callback → Dart `ReceivePort`.
- Versioning: `cc_abi_version()` must match what the generated bindings expect; mismatch blocks startup with a clear build error.

## 5. Media pipeline

- **Probe** (IO pool): container/streams metadata via `avformat`: codecs, dimensions, sample aspect, rotation matrix (applied!), fps as rational (avg + r_frame_rate), VFR detection (comparing frame pts deltas), duration, audio layout, HDR transfer function detection (PQ/HLR → flagged).
- **Decode sessions:** one lazy decoder session per asset reader; hardware decode (VideoToolbox / D3D11VA) attempted first, software fallback always available. Output frames uploaded to GPU as textures keyed by `(assetId, pts, qualityTier)`.
- **Quality tiers:** `full` (native), `half`, `proxy`. Playback picks the highest tier that sustains realtime (auto-downgrades under load, upgrades when idle); export always renders `full`.
- **Thumbnails:** per-clip filmstrip (default 1 thumb/sec capped at 200/clip) rendered once to disk cache, LRU-evicted.
- **Waveforms:** peaks precomputed at 100 peaks/sec/channel to disk cache; drawn by Flutter from cached data.
- **Proxies:** generated in background when any of: height > 1440, bitrate > 60 Mbps, codec ∈ {H.265, AV1}, or VFR phone footage. Format: H.264 yuv420p, 960×540-equivalent (aspect preserved), high-quality audio copy. Proxy creation never blocks editing; clips show a "preparing proxy" shimmer then swap seamlessly.
- **Conform:** VFR sources are conformed to sequence fps (CFR resample) inside proxies; SDR conversion of HDR uses Hable tone mapping at decode; rotation baked into decoded frames.

## 6. Playback engine

- **Clock:** audio-output-driven master clock (sample count). Video presentation targets the nearest sequence frame time; drift corrected by resampling audio ±0.5% silently if skew exceeds 20 ms (long-sequence safety).
- **Frame serving:** the render thread maintains a lookahead of ~3 frames per active video layer. Scrubbing bypasses lookahead: seek requests coalesce (last-wins within 16 ms) and render directly from the nearest cached frame or fast seek (demux to prior keyframe + decode forward).
- **Caches:** decoded-frame LRU (budget: 512 MB GPU-equivalent, configurable), thumbnail cache, peak cache (all disk-backed under OS cache dir; content-addressed by asset hash + tier).
- **Transport:** play/pause, JKL shuttle (±1×/±2×/±4×…), step frame, loop range (in/out). During fast shuttle (>2×), audio plays pitch-corrected if cheap, else muted (documented behavior).
- **Presentation:** composited frame goes to the platform external texture. macOS: `FlutterDesktopGpuSurfaceDescriptor` (Metal). Windows: D3D11 texture interop where the pinned Flutter version supports it; otherwise a zero-copy shared pixel buffer path (CPU readback of final surface) — this is a known risk item (see §12).

> **M0 spike outcome (2026-08):** macOS ships today via the *pixel-buffer* route — the Runner registers a `FlutterTexture` and copies RGBA frames from the engine's playback session into a `CVPixelBuffer` (`kCVPixelFormatType_32RGBA`) at display rate; the engine paces presentation from its audio clock (miniaudio/CoreAudio) with a wall-clock fallback when no device exists. GPU-surface presentation remains the M1+ upgrade path once effects need it. Windows decision (D3D11 interop vs pixel buffer) is still an open spike; the Dart side falls back to frame-stepped JPEG preview wherever native textures are unavailable.

## 7. Render pipeline

- **Graph construction:** from a document snapshot the engine builds a DAG per sequence:
  - Leaf nodes: clip readers (decode → conform → transform → effects stack → opacity).
  - Track compositing: bottom-to-top alpha-over per video track order.
  - Transition nodes: two-input blend spanning the overlap region (see `03-features/transitions.md`).
  - Text nodes: rasterized glyph atlases (platform text stack: CoreText / DirectWrite) cached per (string, style, scale), composited like images so they animate via the same transform/keyframe machinery.
  - Master node: optional loudness-safe master gain; output color convert (RGBA8 → yuv420p at export).
- **Evaluation:** deterministic topological evaluation per frame time `t`. Same document + same `t` ⇒ same pixels (enforced by golden tests).
- **Color processing:** internal pipeline is F16 RGBA linear-light where GPU allows; RGBA8 sRGB elsewhere. v1 exports 8-bit SDR Rec.709. Documented limitation: no float export pipeline until v1.5.
- **Effects:** each effect = parameter schema + fragment kernel(s) + CPU reference. Stack order = application order (top of list applied last). Params are animatable (keyframes evaluated at clip-local time).
- **GPU abstraction:** minimal RHI (device, texture, pipeline, uniform buffer, blit). Backends: Metal, D3D11, CPU (SIMD: SSE4.2/AVX2). Effect kernels authored once in a common subset translated to MSL/HLSL at build time; CPU versions hand-written and kept bit-comparable within tolerance for tests.

## 8. Export pipeline

- Submitting a job serializes the current document (snapshot) + export settings and spawns/reuses the **export child process**, passing the job over stdin (JSON lines protocol: `SubmitJob`, `Progress`, `Log`, `Done`, `Fail`, `Cancel`).
- The worker renders frames sequentially at target fps through the same graph code (quality tier `full`), feeding encoders: x264/x265 (CRF-based quality slider) or ProRes 422; audio AAC 320 kbps (or PCM WAV option); optional two-pass `loudnorm` to −14 LUFS; `+faststart` MP4.
- Hardware encoders (VideoToolbox, NVENC, QSV) are opt-in per job with a quality caveat tooltip.
- Progress events every 250 ms (frame count, fps, ETA); cancel is cooperative (checked between frames); failed jobs clean partial outputs and attach the last 50 log lines.
- Queue lives in the main process (survives worker crashes; auto-retry once). Editing continues freely — jobs operate on their snapshot.

## 9. Data flow example (edit → preview)

1. User drags a clip 10 frames right; timeline widget updates locally (optimistic).
2. On pointer-up, a `MoveClip` command commits: document mutates, undo entry pushes, autosave schedules (debounced 2 s).
3. Controller emits graph delta `{move clip X to track T, start S}` → engine patches graph (~µs), invalidates affected frame cache entries.
4. Render thread recomposites at playhead; texture swaps next vsync. Total budget end-to-end: < 1 frame.

## 10. Error handling & resilience

- Error codes are stable enums grouped by subsystem (`MEDIA_DECODE`, `GPU_DEVICE_LOST`, …); user-facing messages live in Dart localization tables, not the engine.
- GPU device lost (Windows): recreate device, rebuild pipelines, re-upload caches; preview blinks once; if recovery fails twice, fall back to CPU backend for the session and inform the user.
- Missing media at open: clips enter "offline" state (checkerboard + name); relink flow in `03-features/media-import.md`.
- Crash recovery: autosave cadence + backup ring defined in `02-data-model.md`; on launch after crash, offer restore point list.
- Everything the engine does is recoverable by discarding it: the worst-case recovery is "rebuild graph from document".

## 11. Logging & diagnostics

- spdlog ring buffer in-memory (last 2 MB) + rotating file logs (7 days) in OS log dir. Levels: info default; debug toggled per-subsystem from Settings → Diagnostics.
- Help menu → "Copy diagnostics": zips recent log, OS/GPU info, document schema version (never media contents). Opt-in crash reporting (Sentry-compatible endpoint configurable; off by default).

## 12. Performance budget (CI-enforced)

Reference hardware: **M1 MacBook Air 8 GB** and **Ryzen 5 5600 / 16 GB / GTX 1650 / SATA SSD**.

| Action | Budget |
|---|---|
| Cold start → project browser | < 3 s |
| Open 30-min project (500 clips) | < 2 s |
| Seek first frame (scrub) | ≤ 100 ms p95 |
| Preview 1080p · 3 layers · typical effects | 60 fps, < 70% GPU on ref hw |
| Import probe | < 1.5 s/file, non-blocking |
| Thumbnails, 100-clip bin | < 30 s background |
| Undo/redo commit | < 50 ms |
| Export 1080p H.264 default preset | ≥ 1.0× realtime |

Nightly benchmarks run on fixed runners; > 10% regression fails the build (see `05-roadmap.md` §Testing).

## 13. Build & distribution

- Engine: CMake ≥ 3.24 + Ninja; static lib `libcrazycut.dylib/.dll` + separate `crazycut_worker` executable linking the same objects.
- ffmpeg: built from pinned sources by CI scripts (`tools/ffmpeg-build/`), GPL enabled (`--enable-gpl --enable-libx264 --enable-libx265`), deployed as **separate dynamic libraries** next to the app binary (not linked into `libcrazycut`'s public identity beyond dynamic linkage).
- App: standard Flutter desktop builds. Release artifacts: notarized DMG (Developer ID) and signed NSIS installer. Auto-update check = manual "check for updates" hitting GitHub Releases API (v1).
- CI: GitHub Actions — matrix {macOS universal, Windows x64} × {unit, golden, integration, perf-nightly}.

## 14. Licensing compliance

- Application code: **MIT**.
- ffmpeg: bundled as GPL-built separate binaries/libs. Because CrazyCut is open-source and distributed free, combined distribution complies with GPLv2 for the ffmpeg parts; the repo ships license texts + source links in `licenses/` and an About → Licenses panel in-app.
- Escape hatch documented: if CrazyCut ever goes proprietary, switch to LGPL ffmpeg build (drop x264/x265/postproc; use HW encoders + open codecs) — architecture already isolates encoder selection behind `export/` interfaces.
- Other deps respect their licenses (miniaudio MIT, etc.); `licenses/` aggregates all third-party notices, regenerated in CI (`tools/license-check`).

## 15. Security & privacy

- No network access required for core editing. Outbound calls are limited to: explicit update checks, opt-in crash reporting, an LLM endpoint the user configured (absent until then), and a one-time user-confirmed speech-model download. Core editing is fully offline, and with a local LLM provider AI assist is offline too — see `03-features/ai-assist.md` (**AI-1**, **AI-18/19**).
- LLM API keys live in the OS keychain, never in project files, preferences, logs or the diagnostics bundle (**AI-3**). Only transcript text and project metadata are ever sent to a configured endpoint — never media, frames or audio.
- Project files reference absolute/relative local paths; no telemetry about media contents ever leaves the machine.
- Export worker accepts jobs only over its own stdio pipe (no sockets), spawned from the app bundle path.

## 16. Key technical risks

| Risk | Impact | Mitigation |
|---|---|---|
| Flutter Windows external-texture gaps (D3D11 interop) | Preview perf on Windows | Prototype week 1 of M0; pin Flutter version; pixel-buffer fallback path kept warm |
| GPU driver variance (Windows) | Crashes/artifacts | Caps detection, CPU fallback, device-lost recovery, QA matrix |
| Long-GOP/VFR phone footage | Stutter, desync | Proxies + CFR conform; decode hw/sw auto-select |
| A/V drift on long sequences | Unusable audio | Sample-count clock + silent resync (§6) |
| Scope creep toward Resolve | Missed v1 | Non-goals list enforced; feature gate via roadmap milestones |

## Changelog

- v0.1 — Initial draft.
