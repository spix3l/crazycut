# CrazyCut — Roadmap, Risks & Testing Strategy

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-21
> Milestone gates reference requirement ids from `03-features/*`.

## 1. Milestones

Sizing assumes a small team (1–3 engineers); durations are relative (weeks of focused work), not calendar promises. Each milestone ends with a demo-able, testable increment — no big-bang integration.

### M0 — Walking skeleton (~15% of effort)
Prove the riskiest stack decisions end-to-end before any feature polish.
- App shell opens; create/open/save `.crazycut` project (PRJ-1–6 subset).
- Import one H.264 MP4 (IMP-5/6 minimal): probe + poster thumb.
- Play a single clip on V1 with audio through the engine → Flutter external texture (macOS Metal **and** Windows D3D11/pixel-buffer decision made with data).
- Export that clip unmodified to MP4 via worker process.
- **Exit criteria:** seek p95 < 100 ms on ref hw; A/V sync verified on 10-min clip; Windows texture path chosen and documented; CI builds both platforms.

> **Status (2026-08):** macOS path complete — project browser/editor shell, import+probe+thumbs, engine playback with audio-clocked video presented through a Runner-registered `FlutterTexture`, worker export, 14 engine tests + 6 Dart tests green, `tools/check-sync.sh` passes on a 10-min clip (A/V stream drift 37 ms, container drift 3 ms, transcode ≈38× realtime). Open items carried into early M1: Windows texture spike + green Windows CI job, seek-latency benchmark harness, hardware decode selection.

### M1 — Editing core (~25%)
The timeline becomes real.
- Multi-track timeline: move/trim/roll/slip/slide/split, snapping, markers, JKL, zoom (TIM-1–18).
- Undo/redo command system + autosave/backups/recovery (TIM-20/21, PRJ-6–9).
- Thumbnails/waveforms in timeline; proxy generation background (IMP-8).
- **Exit criteria:** TIM acceptance tests pass incl. 500-clip perf suite; crash-recovery drill (kill -9) loses ≤ 30 s.

> **Status (2026-08):** complete. The timeline is a real NLE: move/trim/roll/slip/slide, snapping with a bypass and an indicator, markers with rename and navigation, in/out points with looping, JKL shuttle (incl. K+L creep), pointer-anchored zoom and zoom-to-fit, multi-select with marquee/select-all/invert/track-select, copy-cut-paste-duplicate, linked A/V groups, ripple and magnetic delete, pool drag-drop with insert/overwrite/append preview, track add/remove/rename/reorder/height and mute-solo-lock-hide, frame-exact numeric trim, filmstrips and engine waveforms in lanes with viewport virtualization. Undo is a command stack (entity deltas, ~100 MB budget, one entry per gesture) that every mutation flows through. Autosave/backups/recovery per PRJ-6–9, and background proxy rendering per IMP-8 (worker gained a scaling option). 64 Dart tests + 25 engine tests green, including the TIM acceptance criteria and a 500-clip perf suite.
>
> **Deliberate deviations** (spec self-conflicts, recorded rather than silently resolved): the spec binds ⌥drag to both *duplicate* (TIM-3) and *slip* (TIM-6) — ⌥drag slips and breaks links, duplicate is ⌘D; it binds ⌘ to both *slide drag* (TIM-6) and *snap bypass* (TIM-15) — ⌘drag slides, ⌃ bypasses snapping. Track reordering is a header-menu verb rather than a drag. Not yet built: paste-attributes (⌥⌘V, needs the M2 effect model), marker colours, and hardware-accelerated decode tiers behind the proxy switch.

### M2 — Look & motion (~25%)
- Effect stacks: color basics, blur family (+blur-island), transform/crop, blend modes (FX-*).
- Transitions with handle semantics (TRA-*).
- Text clips + presets/animations; keyframe system across transform/color/text (TXT-*, KEY-*).
- **Exit criteria:** golden-frame suite green (preview==export sampling); keyframed 3-layer composition realtime on ref hw.

### M3 — Audio (~10%)
- Fades/gain/mute/pan, detach/link, mixer panel, normalize, loudness analysis (AUD-1–13).
- **Exit criteria:** AUD acceptance set passes; mixer metering at 60 fps without audio dropouts.

> **Status (2026-08):** complete. One mixdown (`engine/audio/mixer.cpp`) serves monitoring, analysis and export, so preview loudness equals delivered loudness: per-clip gain/pan/mute, fades with linear/exponential/S-curve shapes, equal-power transition crossfades, track faders with mute/solo, master fader and the always-on safety limiter. Realtime monitoring runs through `SequencePlayer` (miniaudio, mix-ahead ring buffer) and its sample count is the master clock the playhead follows. Loudness is BS.1770-4 integrated LUFS with true-peak estimation, measured within 0.1 LU of ffmpeg's `ebur128` on the tone corpus. UI: dB faders and curve pickers in the inspector, draggable corner fade handles that draw the actual curve, detach/relink with an out-of-sync badge and click-to-sync, peak normalize, a mixer panel with peak-hold metering, and output-device selection. 11 golden-audio engine tests + 18 Dart audio tests + 4 FFI audio tests green.
>
> **Deliberate deviations:** AUD-4's "preserve pitch" time-stretch is varispeed only for now (documented in the audio spec as best-effort v1); per-track metering shows master levels with active/inactive strips rather than mixing every track separately, which would double the mix cost for a cosmetic gain.

### M4 — Ship path (~15%)
- Export presets/queue/background jobs/hw encoders/loudnorm (EXP-*).
- Missing-media relink flow (IMP-15–17); collect-files (PRJ-14).
- Installers: notarized DMG, signed NSIS; update check; diagnostics bundle.
- **Exit criteria:** EXP acceptance set passes; clean install→first-export on both OSes by a non-developer tester.

> **Status (2026-08):** export and the media tools are complete; installers are not. The export dialog builds a real job from the document snapshot at submit time and hands it to a queue that runs the worker process while editing continues: the six presets, the Draft→Master quality slider, resolution capping without upscaling, hardware encoders (VideoToolbox/NVENC/QSV/AMF with software fallback), ProRes 422 + 24-bit PCM masters, in/out range export, and two-pass-style loudness normalization to −14 LUFS under a −1.5 dBTP ceiling. Every job writes into `<name>.part` and renames atomically, cleans its partials on failure or cancel, retries an encode failure once, and leaves a `.log.json` sidecar. The queue panel shows progress/fps/ETA with cancel, reveal, open and copy-path actions, the toolbar button carries a progress ring, and quitting mid-export asks first (and the machine is kept awake while jobs run). Missing media relinks by content hash first and filename second, one folder at a time, never pointing two clips at one file; collect-files copies media into `<project>/Media/` with the size shown up front; a diagnostics bundle lands beside the project. 21 Dart tests cover presets, the queue, a real end-to-end render, relink and collect.
>
> **Packaging:** `tools/package-macos.sh` builds a release engine + app, embeds `libcrazycut.dylib` and `crazycut_worker` inside the bundle (the app now looks beside its executable before the dev build tree) and produces `dist/CrazyCut.dmg`. Signing and notarization are wired but opt-in through `CC_SIGN_IDENTITY` / `CC_NOTARY_PROFILE`, so an unsigned DMG builds today and a notarized one builds the moment credentials exist.
>
> **Not built:** the signed Windows NSIS installer, the update check (there is no release feed to check against yet), and relocating the ffmpeg dylibs into the bundle — the packaged app still resolves them from their Homebrew install paths.

### M5 — Beta hardening (~10%)
- Perf tuning against budgets; memory soak (8 h session); fuzz project loader.
- Onboarding sample project + guided checklist (UIX-7); docs site (user + this spec set published).
- Opt-in telemetry wired to success metrics (`00-product-overview.md` §8).
- **Exit criteria:** crash-free sessions ≥ 99.5% over beta cohort; all v1 non-goals still out ; public beta tagged v0.9.

## 2. Testing strategy

| Layer | Tooling | What |
|---|---|---|
| Engine unit | GoogleTest | rational time math, model validation/invariants, keyframe eval, graph topology, loudness math |
| Golden frames | GoogleTest + perceptual diff (ΔE) | deterministic compositions rendered CPU vs GPU vs checked-in references; preview==export sampling |
| Golden audio | GoogleTest | fade curves RMS, crossfade midpoint ±0.5 dB, loudnorm targets |
| Serialization fuzz | libFuzzer | project JSON loader never crashes/quarantines cleanly |
| Dart unit/widget | flutter_test | stores, commands/undo, inspector bindings, theme lint (contrast) |
| Integration | flutter integration_test + tiny generated media fixtures | import→edit→export smoke per milestone exit criteria |
| Perf | nightly CI on fixed runners | budget table from `01-architecture.md` §12; >10% regression fails build |
| Manual QA | scripted checklists per release | platform matrices: macOS 13/14/15 × AS/Intel; Win10/21H2+ × NVIDIA/AMD/Intel iGPU |

Fixtures are generated programmatically (synthetic color bars, moving gradients, tone sweeps) so tests never depend on licensed media.

## 3. Risk register

| # | Risk | P×I | Mitigation | Owner signal |
|---|---|---|---|---|
| R1 | Flutter Windows external-texture interop underperforms | M×H | M0 spike decides D3D11 vs pixel-buffer; pixel-buffer path kept optimized (SIMD readback) | M0 exit |
| R2 | GPU driver variance breaks effects on Windows | M×M | caps detection, CPU fallback, device-lost recovery, QA matrix | M2 |
| R3 | Realtime budget missed with effects+keyframes | M×H | tiered quality auto-downgrade, proxies, nightly perf CI from M0 onward | every M |
| R4 | Scope creep toward Resolve features | H×H | non-goals list is spec-law; new ideas → backlog doc, not code | continuous |
| R5 | ffmpeg GPL build maintenance burden | L×M | pinned sources + scripted CI builds; LGPL escape hatch documented | M0 |
| R6 | A/V drift long sequences | L×H | sample-count clock + resync (arch §6); 10-min sync test in M0 | M0/M3 |
| R7 | Solo-creator UX still "too NLE" | M×H | usability sessions each milestone (n≥5 creators); task-completion metric: cut+text+export < 15 min first try | M2/M5 |

## 4. Post-v1 candidates (backlog seeds)

Custom LUT import · curves/wheels · bezier graph editor · volume automation lanes · audio FX (EQ/comp) · auto-captions (local whisper-class model) · speed ramps/time remap · nested sequences · direct upload integrations · Linux support · HDR delivery.

Nothing here enters v1 scope; each gets a feature-spec doc before implementation.

Reusable templates left this list early and shipped against its own spec
(`03-features/templates.md`, **TPL**), driven by the section-announcement
workflow: build a bumper once, re-announce each section by typing a title.

## Changelog

- v0.1 — Initial draft.
