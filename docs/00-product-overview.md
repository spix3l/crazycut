# CrazyCut — Product Overview

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-21

## 1. Vision

**CrazyCut is a desktop video editor that feels as easy as Canva and cuts as fast as Resolve — for the 20% of editing power that solo creators actually use, 100% of the time.**

Free editors today force a choice: professional tools (DaVinci Resolve) that are powerful but heavy, slow to learn, and demanding on hardware; or consumer tools (CapCut web/desktop free tier, Canva video) that are simple but gutted, watermarked, or online-only. CrazyCut occupies the gap: a native, offline, open-source (MIT) editor for solo creators who want multi-track editing, effects, text animation, and clean exports without a film-school learning curve.

One-liner: *Edit fast. Export clean. Own your tool.*

## 2. Problem

Solo creators (YouTubers, TikTokers, course makers, indie founders) lose hours per week to their editor:

1. **Slow tools.** Browser-based editors choke on long rushes; Electron apps eat RAM; Resolve needs a beefy GPU and proxies done right.
2. **Atrocious UX.** NLEs expose 40 years of broadcast conventions (source/record, decks, scopes) that a vlogger will never need.
3. **Gated basics.** Free tiers watermark exports, cap resolution, or push cloud subscriptions for features (captions, keyframes) that are trivially local.

CrazyCut's bet: a small, ruthless feature set executed with native performance (Flutter UI + C++ engine + ffmpeg) and Canva-grade interaction design wins this audience.

## 3. Target users

Primary: **solo creators** publishing to YouTube, TikTok/Reels/Shorts, and course platforms. They edit alone, on one machine, weekly or daily.

### Personas

| | Maya, 26 — Beauty YouTuber | Dev, 19 — Shorts/TikTok creator | Sam, 31 — Indie founder |
|---|---|---|---|
| Volume | 2 videos/week, 10–20 min each | Daily shorts, 30–90 s | 2–4 demos/month |
| Rushes | Screen cam + b-roll, 1080p/4K H.264 | Phone vertical, mixed HDR/SDR | Screen recordings + stock |
| Must-have | Cut, punch-ins, captions, music ducking | Speed, captions, transitions, trends-fast | Text overlays, zooms, crisp export |
| Current pain | Resolve timeline anxiety; CapCut watermark | Mobile app fiddliness at volume | Premiere overkill; web tools lag |
| Hardware | M1 MacBook Air | Mid Windows laptop (GTX 1650) | Work laptop, no dGPU |

All three share the same loop: **import → cut → polish → export**, in one sitting, tonight.

## 4. Jobs to be done

- *When I drop my rushes in, I want to start cutting within seconds*, so I don't break flow waiting for imports/proxies.
- *When I trim and move clips, I want it to feel instant*, so editing stays rhythmic.
- *When I add text or an effect, I want a good default and one obvious knob*, so I never open a manual.
- *When I hit export, I want the exact preview, at full quality, while I keep working*, so shipping isn't a coffee break.
- *When the app crashes, I want every cut back*, so I never re-edit.

## 5. Goals & non-goals (v1)

### Goals
1. Multi-track NLE timeline (unlimited video/audio tracks) with fluid trimming, snapping, ripple, JKL.
2. Import rushes painlessly: drag-drop, probing, thumbnails, waveforms, automatic proxies for heavy media.
3. Effects: color basics, blur family, transform/crop, blend modes — stacked per clip, reorderable.
4. Transitions between clips (dissolve, dips, slide, push, zoom) with automatic handle management.
5. Text overlays with presets and animations; property **keyframes** (position/scale/rotation/opacity/color/blur/volume).
6. Audio tools: gain, fades, mute, pan, detach audio, music track, mixer, loudness-normalized export.
7. Projects management: browser, autosave, backups, crash recovery, settings presets (16:9 / 9:16 / 1:1).
8. Background export queue with presets (YouTube, TikTok/Reels, custom), H.264 default, HEVC/ProRes options.
9. Native performance budgets (see §8) on mid-range hardware — "not slow" is a feature, measured in CI.

### Non-goals (v1)
- Multicam, color wheels/scopes/curves, speed ramps/time-remap curves (basic constant speed only).
- Templates marketplace, stock media library, cloud sync/collaboration, direct social upload.
- Plugins/scripting API, mobile/web builds, HDR delivery (HDR input is tone-mapped to SDR), subtitle/caption file tooling (plain text clips only).
- Linux as a supported target (best-effort only).

Candidates for v1.5+ are tracked in `05-roadmap.md`.

## 6. Product pillars

1. **Fast is a feature.** Every interaction has a latency budget; regressions fail CI like test failures.
2. **Simple surface, deep core.** Defaults do the right thing; advanced controls appear in context (progressive disclosure), never in modal walls.
3. **WYSIWYG, guaranteed by construction.** Preview and export run through the same render pipeline — what you see is byte-for-byte what renders.
4. **Yours.** Local-first files, open source (MIT), no account, no watermark, no telemetry without opt-in. AI assist keeps this promise: speech-to-text runs locally, and the LLM layer is vendor-neutral with a fully local provider option. CrazyCut never holds an account or an API key of its own — the user points it at an endpoint they chose, and only transcript text ever leaves the machine, never media. See `03-features/ai-assist.md`.

## 7. Competitive landscape

| | CrazyCut | DaVinci Resolve (free) | CapCut (free tier) | Canva Video | Kdenlive/Shotcut |
|---|---|---|---|---|---|
| Learning curve | Low | High | Lowest | Lowest | Medium-high |
| Multi-track NLE | Yes | Yes | Basic | No | Yes |
| Native speed | Native C++/GPU | Native | Web/Electron-ish | Cloud | Native |
| Keyframes/effects | Yes (v1) | Deep | Partially gated | Limited | Yes |
| Watermark/export caps | None | None | Often | Yes (some) | None |
| Offline | Fully | Fully | Partial | No | Fully |
| License | MIT, open source | Proprietary | Proprietary | Proprietary | GPL, open source |

Positioning sentence: *"Resolve's honest subset at CapCut's effort."*

## 8. Success metrics

Activation & retention (opt-in telemetry only):
- **Time-to-first-export**: median < 10 min from first launch (onboarding sample project provided).
- **D7 retention** of creators who complete a first export ≥ 35%.
- Crash-free sessions ≥ 99.5%.

Performance (enforced in CI against reference hardware — see `01-architecture.md` §Performance budget):
- Scrub/seek to first frame ≤ 100 ms p95.
- Realtime preview: 1080p sequence, 3 layers + typical effects, 60 fps on M1 Air / GTX 1650-class GPU.
- Export ≥ 1.0× realtime for 1080p H.264 on reference hardware.

Adoption proxies (open source): GitHub stars, release downloads, issue responsiveness (< 48 h median first response).

## 9. Platform & licensing summary

- **Targets:** macOS 13+ (Apple Silicon + Intel), Windows 10/11 x64. Linux best-effort, unsupported.
- **Stack:** Flutter (UI) + C++17 core via FFI + ffmpeg libraries (decode/probe/render/encode). GPU compositing via Metal (macOS) / D3D11 (Windows), CPU SIMD fallback.
- **License:** application code MIT. ffmpeg bundled as separate GPL-built binaries (x264/x265 included); compliance details in `01-architecture.md` §Licensing.
- **Files:** `.crazycut` project files are local JSON (see `02-data-model.md`); media referenced in place, never moved or modified.

## 10. Spec map

| Area | Doc |
|---|---|
| System architecture | `01-architecture.md` |
| Data model & project format | `02-data-model.md` |
| Projects management | `03-features/projects.md` |
| Media import | `03-features/media-import.md` |
| Timeline & editing | `03-features/timeline.md` |
| Effects | `03-features/effects.md` |
| Transitions | `03-features/transitions.md` |
| Text & keyframes | `03-features/text-keyframes.md` |
| Audio | `03-features/audio.md` |
| Export | `03-features/export.md` |
| AI assist (transcription + LLM providers) | `03-features/ai-assist.md` |
| Shorts | `03-features/shorts.md` |
| UI/UX system | `04-ui-ux.md` |
| Roadmap, risks, testing | `05-roadmap.md` |

## 11. Glossary

- **Rush** — raw imported footage. **Sequence** — the editable timeline; v1 projects contain exactly one.
- **Clip** — a ranged reference to an asset placed on a track. **Handle** — unused source frames beyond a clip's in/out points.
- **Proxy** — lightweight stand-in media used for smooth playback; swaps invisibly at export.
- **Render graph** — the deterministic node graph the compositor evaluates to produce each frame.
- **Conform** — adapting differing fps/resolution media to the sequence's settings.

## Changelog

- v0.1 — Initial draft.
