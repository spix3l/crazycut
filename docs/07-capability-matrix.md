# CrazyCut — Capability Matrix

> Status: Living document · Last verified: 2026-08-30

Legend: **Verified** has automated end-to-end coverage on the named platform;
**Implemented** is present and locally tested but lacks full platform evidence;
**Foundation** has persisted/core contracts but no complete user workflow;
**Partial** is usable with important omissions; **Missing** is not implemented.

| Area | Status | Current boundary |
|---|---|---|
| Timeline editing | Verified (macOS) | Multi-track move/trim/roll/slip/slide/split, ripple, snapping, markers, JKL, selection, paste settings |
| Undo, autosave, recovery | Verified (macOS) | Command deltas, atomic autosave, backups, recovery chooser |
| Media preparation | Implemented | Probe, poster, filmstrip, waveform, proxy, relink, collect; source viewer and bins missing |
| Effects and motion | Verified (CPU) | Color basics, blur, crop, transform, blend, transitions, text, keyframes; masks/LUTs/chroma key absent |
| Captions | Implemented (macOS) | Typed tracks/cues/words/styles, transcript conversion, SRT/WebVTT interchange, synchronized editor, undoable edits, preview/export burn-in, and optional sidecars; physical Windows rendering evidence remains required |
| Audio | Verified (macOS) | Gain, pan, fades, mixer, loudness, normalization, limiter; cleanup DSP, automation, ducking, and VO absent |
| Export | Verified (macOS) | Background queue, H.264/HEVC/ProRes, in/out, loudness, cancellation and atomic output |
| AI and transcription | Implemented | Local transcription and provider-neutral shorts flow; model-dependent transcription test is optional |
| Onboarding | Implemented | Offline generated sample and persistent dismissible checklist; formal first-user study pending |
| CPU preview/compositor | Verified (macOS) | Shared deterministic preview/export render path |
| Hardware encoding | Implemented | VideoToolbox/NVENC/QSV/AMF selection with software fallback |
| Hardware decoding | Missing | Decode remains software |
| GPU compositing | Missing | Advertised Metal/D3D11 compositor is not yet implemented |
| HDR input | Partial | Detection/color metadata exist; a validated PQ/HLG tone-map pipeline is missing |
| macOS distribution | Partial | Self-contained DMG (engine, worker, ffmpeg, whisper/ggml all embedded); signing/notarization wired and local-credentialed — needs a Developer ID cert + notary profile (docs/quality/macos-signing.md) |
| Windows build | CI gate added | Native/app build and packaged ABI/playback/export smoke are release-blocking; physical Win10/11 QA remains required |
| Windows installer | Missing | Current artifact is a ZIP, not a signed installer |
| Updates | Missing | No signed update feed or updater |
| Accessibility/i18n | Partial | Some keyboard behavior and contrast design exist; ARB localization and complete semantic/focus audit are missing |
| Area tracking | Implemented (macOS) | Region solve (OpenCV, static, `CC_WITH_TRACKING`), `trackers[]`, corner-pin warp in the shared preview/export compositor, canvas tool (menu bar + inspector), Track tab with live progress, and a timeline confidence stripe. Deterministic and cancellable, with engine and Dart coverage including a known-motion fixture and Dart↔engine warp parity. Windows build and physical QA of the solver remain unverified |
| Multiple sequences | Missing | One sequence per project |

## Evidence gates

- macOS correctness: `.github/workflows/ci.yml`, Flutter suite, native CTest.
- Windows headless contracts: `tools/smoke-windows.ps1` and
  `docs/quality/windows-validation.md`.
- Representative performance: `app/test/representative_perf_test.dart` and
  `tools/perf/`; accepted numbers require the labeled fixed runner.
- Creator-ready delivery order: `06-implementation-plan.md`.

Update this matrix in the same change that adds, removes, or materially changes
a capability. Do not promote Windows, GPU, HDR, installer, or updater status
from CI compilation alone.
