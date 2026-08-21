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

### M2 — Look & motion (~25%)
- Effect stacks: color basics, blur family (+blur-island), transform/crop, blend modes (FX-*).
- Transitions with handle semantics (TRA-*).
- Text clips + presets/animations; keyframe system across transform/color/text (TXT-*, KEY-*).
- **Exit criteria:** golden-frame suite green (preview==export sampling); keyframed 3-layer composition realtime on ref hw.

### M3 — Audio (~10%)
- Fades/gain/mute/pan, detach/link, mixer panel, normalize, loudness analysis (AUD-1–13).
- **Exit criteria:** AUD acceptance set passes; mixer metering at 60 fps without audio dropouts.

### M4 — Ship path (~15%)
- Export presets/queue/background jobs/hw encoders/loudnorm (EXP-*).
- Missing-media relink flow (IMP-15–17); collect-files (PRJ-14).
- Installers: notarized DMG, signed NSIS; update check; diagnostics bundle.
- **Exit criteria:** EXP acceptance set passes; clean install→first-export on both OSes by a non-developer tester.

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

Custom LUT import · curves/wheels · bezier graph editor · volume automation lanes · audio FX (EQ/comp) · auto-captions (local whisper-class model) · speed ramps/time remap · nested sequences · templates · direct upload integrations · Linux support · HDR delivery.

Nothing here enters v1 scope; each gets a feature-spec doc before implementation.

## Changelog

- v0.1 — Initial draft.
