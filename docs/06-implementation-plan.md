# CrazyCut — Creator-Ready v1 Implementation Plan

> Status: In progress · Last updated: 2026-08-30
> Purpose: bounded, dependency-aware work packages for future agent delegation.

## 1. Target outcome

CrazyCut v1 is ready when a first-time solo creator can import real phone or
screen-recording footage, review and cut it, add accurate captions, clean up
dialogue, create horizontal and vertical versions, and install/export reliably
on macOS and Windows without developer assistance.

Cloud collaboration, multicam, plugins, stock media, and professional grading
remain outside this plan.

## 2. Delivery rules

1. A feature is complete only when model, undo/redo, preview, export,
   persistence, recovery, UI, and tests agree.
2. Preview and export must evaluate the same document state.
3. Schema changes require old fixtures, migrations, round-trip tests, and
   forward-safe preservation of unknown fields.
4. Performance claims require representative fixtures and CI thresholds.
5. Platform features require evidence from the platform they claim to support.
6. New application settings must persist beyond one `EditorController`.
7. Every package lands independently green and updates the capability matrix.

## 3. Coordination and ownership

Assign one integration owner at a time to each hotspot:

| Hotspot | Coordination rule |
|---|---|
| `app/lib/data/project.dart` | One schema owner per milestone |
| `app/lib/state/editor_controller.dart` | Feature agents build services first; integration owner wires them |
| `app/lib/state/timeline_edits.dart` | Serialize caption, retiming, and multi-sequence changes |
| `engine/render/renderer.cpp` | One render owner; new effects use narrow interfaces |
| `engine/apps/worker/timeline_job.cpp` | One export owner during caption/color/GPU work |
| `editor_screen.dart` | UI integration owner composes completed panels |

Recommended parallel streams:

- A — captions and creator workflow.
- B — render performance and color correctness.
- C — Windows, release engineering, and quality.
- D — onboarding, media review, and accessibility.

Audio, creator effects, and multi-sequence work begin after the first three
streams stabilize shared model and renderer contracts.

## 4. Milestones and work packages

### Milestone A — Honest baseline and release gates

#### A1. Capability matrix and spec reconciliation — Small

- Replace the stale README status.
- Track implemented, partial, missing, and OS-verified capabilities.
- Separate hardware encode, hardware decode, and GPU-compositing claims.
- Derive codec support from the bundled build.

Gate: README, roadmap, architecture, and UI do not contradict one another;
every advertised capability links to evidence or is marked experimental.

#### A2. Representative performance harness — Medium

- Generate 1080p60 and 4K30 fixtures, including HEVC/VFR where available.
- Benchmark one layer, three layers, keyframes, blur, text, transitions,
  scrubbing, and export.
- Capture p50/p95 seek, dropped frames, CPU, peak memory, and export speed.
- Run correctness on ordinary CI and performance gates on fixed runners.

Gate: the published three-layer 1080p60 scenario is reproducible and a greater
than 10% regression fails CI. Results state resolution, proxy, and acceleration
state.

#### A3. Windows CI and validation — Medium

- Remove `continue-on-error` from Windows CI.
- Build the Flutter Windows app, not only the engine.
- Smoke-test project open, texture delivery, audio devices, and worker export.
- Run import-to-export QA on Windows 10/11 and representative GPUs.

Gate: Windows failures block releases and a tagged build has passed real
install-to-export testing.

### Milestone B — Captions and first-export experience

#### B1. Caption model and migration — Medium — **Complete (macOS)**

Use a typed caption track, not unrelated text clips:

```text
CaptionTrack { id, name, language, style, items[] }
CaptionItem  { id, start, duration, text, speaker?, words?[] }
CaptionWord  { start, end, text, confidence? }
```

- Use exact sequence time and define overlap/minimum-duration repair.
- Preserve word timing for highlighted-word styles.
- Add command deltas so text, timing, and style edits are undoable.

Gate: old projects load unchanged; caption round-trip, repair, duplicate,
autosave, recovery, and undo tests pass.

#### B2. Transcript conversion and interchange — Medium — **Complete (macOS)**

- Convert cached transcripts to cues using silence, line length, duration, and
  reading-speed rules.
- Import/export SRT and WebVTT with validation and repair reporting.

Gate: a ten-minute transcript becomes editable captions in one action; SRT/VTT
round-trips within one frame without a network provider.

#### B3. Caption editor UI — Large — **Complete (macOS)**

- Add a caption timeline lane and synchronized list/transcript editor.
- Support edit, search/replace, split, merge, nudge, retime, speaker, and bulk
  style operations.
- Add safe-area placement, presets, highlighted-word styling, and non-blocking
  reading-speed warnings.

Gate: keyboard-only correction is possible; one commit is one undo step; list,
monitor, lane, selection, and playhead remain synchronized.

#### B4. Caption render and export — Large — **Complete (macOS)**

- Render captions through the shared preview/export path with layout caching.
- Support burned-in output and optional SRT/VTT sidecars.
- Verify Unicode, multiline, fallback fonts, safe margins, and 9:16 layouts.

Gate: golden tests cover cue boundaries and preview/export parity; sidecar
timing reflects final edits; rendering meets the frame budget.

#### B5. Onboarding and sample project — Medium — **Complete (macOS)**

- Add a license-safe sample and import → cut → captions → text → export
  checklist.
- Add dismissible one-time hints for trim modes, keyframes, proxies, and export.

Gate: a new user can finish the guided export without external docs and the
sample participates in project migration tests.

### Milestone C — Performance, color, and shipping

#### C1. Render-backend abstraction — Large

- Separate decode, effect evaluation, composition, and presentation.
- Keep CPU as the deterministic reference.
- Define GPU surface ownership, format, color metadata, and fallback first.

Gate: existing CPU goldens remain unchanged and diagnostics expose backend and
fallback state.

#### C2. Hardware decode — Large

- Add VideoToolbox on macOS and D3D11VA on Windows.
- Avoid readback with GPU composition; retain automatic software fallback.
- Test seek, VFR, rotation, 10-bit, decoder exhaustion, and device loss.

Gate: supported H.264/HEVC reports hardware decode and fallback never changes
sequence timing.

#### C3. GPU compositing and effects — Extra Large

- Implement Metal, then D3D11, against C1.
- Port transforms, blending, color basics, blur, crop, transitions, text,
  images, and captions.
- Keep keyframe evaluation backend-independent and compare CPU/GPU goldens.

Gate: the three-layer 1080p60 fixture meets budget on reference hardware;
device loss recovers or falls back; output stays within perceptual tolerance.

#### C4. Color management and HDR-to-SDR — Large

- Carry primaries, transfer, matrix, range, and bit depth end to end.
- Define the SDR working/output space and deterministic PQ/HLG tone mapping.
- Add mixed SDR/HDR fixtures and validate export metadata.

Gate: HDR input is neither washed out nor clipped and CPU/GPU agree within the
chosen tolerance.

#### C5. Installers, dependencies, signing, and updates — Large

- Bundle FFmpeg/runtime libraries and test clean machines.
- Sign/notarize macOS; build a signed Windows installer and uninstall flow.
- Add a signed update manifest, manual check, and safe opt-in updater.
- Test upgrade, failure, and project preservation.

Gate: both platforms install without developer tools or Homebrew paths; failed
updates leave the current installation usable.

### Milestone D — Media review and dialogue workflow

#### D1. Source viewer and three-point editing — Large

- Add source playback, audio, scrub, in/out, metadata, and persistent marks.
- Insert/overwrite a source range at the sequence playhead.

Gate: source review never mutates the timeline; insert/overwrite are frame
exact and undo in one step.

#### D2. Media-pool completion — Medium

- Implement sortable columns for name, type, duration, resolution, codec,
  status, and usage.
- Add import-order/duration sorting, multi-select, preview, properties, safe
  removal confirmation, and lightweight bins/labels.

Gate: 1,000 assets remain responsive and removing used media clearly reports
impact and remains recoverable.

#### D3. Dialogue cleanup DSP — Large

- Add high-pass, simple EQ, compressor, de-esser, and dialogue denoise.
- Provide restrained presets; share DSP between monitoring and export.

Gate: golden audio covers bypass, extremes, latency, and clipping; effects do
not interrupt realtime playback.

#### D4. Ducking, automation, and voice-over — Large

- Add track/clip volume automation lanes.
- Generate editable ducking from dialogue activity.
- Record an input device atomically into a new asset and timeline clip.

Gate: ducking is editable/undoable; ten-minute voice-over stays synchronized;
permission denial and device removal fail safely.

### Milestone E — Creator visuals and edit versions

#### E1. Chroma key and masks — Large

- Add key color, tolerance, spill suppression, edge softness, and matte view.
- Add rectangle/ellipse/freeform masks with invert, feather, and keyframes.

Gate: CPU/GPU goldens cover alpha edges; masks compose correctly with crop,
transform, effects, and blend modes.

#### E1b. Area tracking — Extra Large

Spec: `03-features/tracking.md` (**TRK**). Sibling of E1 — both add region
geometry to the compositor — but independent of it: E1 masks a clip against
itself, E1b moves one clip with another's pixels. Sequenced as six packages so
each lands green on its own, because it touches four §3 hotspots.

- **T1 Model.** `trackers[]` and the transform's `corners` param in both the
  Dart and C++ models; validation, quarantine, round-trip.
- **T2 Warp.** Projective branch in `rasterizeLayer`, mirrored in
  `canvas_geometry.dart`; export passthrough excludes pinned clips.
- **T3 Solver.** OpenCV (static, trimmed) behind `CC_WITH_TRACKING`; feature
  flow + RANSAC homography over engine-decoded frames.
- **T4 Job.** `track` worker job on the existing JSON-lines protocol, and its
  Dart service.
- **T5 UI.** Canvas draw tool, Track inspector tab, pin/unpin/bake/re-track ops.
- **T6 Evidence.** Capability-matrix row, build note, perf fixture.

Gate: a solve is deterministic and cancellable leaving nothing behind; an
identity quad renders bit-identically to the non-corner path; export of a pinned
clip matches preview bit for bit; a corrupt tracker is quarantined without
losing siblings; undo of a solve commits inside 50 ms.

#### E2. LUTs, adjustment layers, and effect presets — Large

- Import/validate `.cube` LUTs.
- Add bounded adjustment clips affecting lower visible tracks.
- Save named effect-stack presets separately from chunk templates.

Gate: missing LUTs are relinkable and adjustment order matches preview/export.

#### E3. Freeze frames and speed ramps — Large

- Add explicit freeze-frame creation.
- Extend constant speed to piecewise retime segments with simple presets.
- Add pitch-preserving audio or an explicit detach/mute policy.

Gate: source bounds and frame-exact cuts survive ramps; transitions, captions,
audio, split, trim, undo, and export work across boundaries.

#### E4. Multi-sequence schema — Extra Large

- Migrate to project-level media plus `sequences[]` and an active sequence id.
- Add create, duplicate, rename, delete, tabs, and per-sequence export.
- Make autosave, templates, shorts, relink, posters, and diagnostics aware.

Gate: existing projects migrate losslessly; horizontal/vertical sequences share
media; every command targets an explicit sequence.

### Milestone F — Beta hardening

#### F1. Fuzzing and recovery — Medium

Fuzz project, template, transcript, caption, and export-job parsing. Test
truncated writes, corrupt autosaves, newer schemas, and missing caches.

#### F2. Soak and interruption testing — Large

Run eight-hour playback/edit/export soaks while tracking decoders, threads,
handles, textures, memory, and cache growth. Exercise sleep/wake, device
changes, removable media loss, disk full, worker crash, and cancellation.

#### F3. Accessibility and localization — Large

Externalize strings to ARB; add semantics, focus order, focus visibility, and
keyboard access. Test UI scaling, high contrast, reduced motion, long strings,
and RTL-safe layout.

#### F4. Crash and diagnostics loop — Medium

Keep a privacy-preserving local crash record and one-click diagnostics export.
Any remote reporting is explicit opt-in and excludes media and secrets.

Gate: crash-free beta sessions reach 99.5% with a documented sample; no known
data-loss bug remains; import-to-export is keyboard operable on both platforms.

## 5. Dependency graph

```text
A2 perf baseline ──> C1 backend ──> C2/C3 ──> C4
A3 Windows gate ─────────────────────────────> C5

B1 caption model ──> B2 conversion
        └──────────> B3 editor ──> B4 render/export ──> B5 onboarding

D1 source viewer ──> D2 media pool
D3 audio DSP ──────> D4 ducking/voice-over

C1/C3 + B4 ───────> E1/E2
T1 model ──> T2 warp ──┐
T3 solver ──> T4 job ──┴──> T5 UI ──> T6 evidence   (E1b, independent of E1)
D4 timing contract ───────────────> E3
B1 + stable commands ─────────────> E4

All milestones ───────────────────> F1/F2/F3/F4
```

Safe early parallelism: A2, A3, B1, and B5 discovery. B3/B4 begin after B1
freezes the caption contract. C2 and Metal C3 can overlap after C1 freezes GPU
surface ownership. Do not overlap multi-sequence, caption-schema, and retiming
schema changes.

## 6. Suggested agent assignments

| Assignment | Main area | Dependency |
|---|---|---|
| Capability matrix | README/docs | None |
| Perf fixtures/reporter | tests/CI | None |
| Windows mandatory build/smoke | CI/windows/tools | None |
| Caption model/migration | data model/commands | B1 design |
| SRT/VTT and segmentation | new codecs/services | B1 |
| Caption editor | new widgets/state | B1 |
| Caption render/sidecars | rasterizer/renderer/export | B1 |
| Source-player service | new state/engine wrapper | None |
| Media pool completion | media widgets | D1 API |
| Audio DSP nodes | engine/audio | DSP spec |
| Voice-over service | runners/new state service | Audio asset contract |
| Render backend interfaces | engine/render | A2 |
| macOS hardware decode | engine/macos | C1 |
| Windows hardware decode | engine/windows | C1 |
| Metal compositor | new backend | C1 |
| D3D11 compositor | new backend | C1 |
| Installer/runtime bundling | tools/platform packaging | A3 |
| Onboarding/checklist | projects/editor UI | Stable caption labels |
| Accessibility/i18n | app/core widgets | Stable UI surfaces |
| Fuzz/soak harness | engine/integration/CI | Stable schemas |

## 7. Definition of done

Every assignment supplies:

- A spec amendment and explicit non-goals.
- Serialization tests where state persists.
- Undo/redo and autosave/recovery coverage for mutations.
- Preview/export parity tests for rendered or mixed output.
- Keyboard, error, empty, and loading states for UI.
- Performance evidence for playback/render/timeline/audio hot paths.
- Platform evidence for platform-specific work.
- Updated capability matrix and user documentation.

Unit tests alone do not close a package; its milestone scenario must pass end to
end.

## 8. First delegation wave

1. **Caption model/spec agent:** B1 only; freeze persistence and command shape.
2. **Performance agent:** A2 only; establish baselines before optimization.
3. **Windows/release agent:** A3 plus a C5 inventory; make CI authoritative.
4. **UX/onboarding agent:** design B5 and sample content, avoiding the editor
   shell until caption labels stabilize.

After integrating that wave, delegate B2/B3/B4, C1, and D1. This gives useful
parallelism without allowing schema and renderer contracts to drift.
