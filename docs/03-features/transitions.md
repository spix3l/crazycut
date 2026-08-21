# Feature Spec — Transitions

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-21
> Requirements prefix: **TRA** · Model: `02-data-model.md` §5 · Rendering: `01-architecture.md` §7

## Summary

Transitions join two clips on the same track with a blend, without handle juggling: CrazyCut automatically reveals media handles to create the overlap, and falls back gracefully when handles don't exist. Audio crossfades pair automatically.

## User stories

- As Dev, I select two clips, hit the transition button, and it just dissolves — no trimming math.
- As Maya, I drag a dissolve's edge to retime it and the preview updates live.
- As Sam, I want dip-to-black between chapters and a hard cut everywhere else.

## Functional requirements

### Catalog (v1)
| Type | Variants | Default params |
|---|---|---|
| Cross dissolve | — | ease-in-out |
| Dip to black / white | — | center dip |
| Slide | left/right/up/down | ease-out |
| Push | left/right/up/down | linear (both frames move) |
| Zoom | in/out | ease-in-out |

### Placement semantics
- **TRA-1** Apply via: context menu on a cut point ("Add transition"), drag from Transitions gallery onto a cut, or shortcut (Cmd+T = last-used type, default cross dissolve).
- **TRA-2** Creating a transition between butt-joined clips A|B creates an overlap by **extending both clips toward each other using available media handles** (A extends its out, B extends its in). Sequence timing of all other clips is unchanged; total occupied span unchanged.
  - Duration default 0.5 s; max = min(A tail handles, B head handles).
  - Asymmetric fallback: if only one side has handles, overlap shifts accordingly (`alignment` auto-set to start/end); UI explains once via tooltip.
  - No handles either side: refused with inline toast "No extra media at this cut — trim the clips to make room" + highlight trimmable edges.
- **TRA-3** Images/text clips have infinite handles: transitions always available against them.
- **TRA-4** Manual drags cannot create overlaps (TIM-4); overlaps exist **only** as transition spans. Deleting either clip deletes the transition; deleting the transition restores butt-joint at original positions (handles return to normal).
- **TRA-5** One transition per cut point per track; dropping onto an existing transition replaces its type, preserving duration.
- **TRA-6** Retiming: drag transition edge (or inspector duration field); growth consumes more handles with TRA-2 rules; shrinking returns handles. Alignment options: center/start/end (which side absorbs asymmetry).

### Behavior details
- **TRA-7** Easing per transition: linear / ease-in / ease-out / ease-in-out (default per catalog table).
- **TRA-8** Audio pairing: if either clip has linked/own audio, a constant-power audio crossfade spans exactly the transition span (auto-created, editable as fades afterwards — deleting video transition does not delete existing audio crossfade).
- **TRA-9** Transition at sequence start/end (single-sided): applying "dip" types renders from/to black; dissolve types are unavailable single-sided (button disabled with reason).
- **TRA-10** Speed-changed clips participate normally; handle availability accounts for speed (source-side handle seconds × speed).
- **TRA-11** Transitions render through the two-input node path (`01-architecture.md` §7); preview during scrub shows blended frame exactly as export.

## UX notes

- Cut points with room show a subtle transition affordance on hover (small ⧫ between clips); clicking opens quick-pick of the 6 catalog types.
- Selected transition shows duration handles on both sides in the timeline; dragging previews live on the program monitor.
- Transitions gallery (inspector tab when selected): grid of animated preview thumbnails (looping 1 s), searchable, favorites.

## Edge cases

- Trim a clip into its own transition's consumed range: transition shrinks first; further trim deletes transition (with undo) rather than breaking invariant `overlap == duration`.
- Ripple delete before A: B slides left; transition follows its clips (references by id survive).
- Undo of TRA-2 creation restores exact prior handle state in one step.
- Transition spanning a clip boundary where one side is offline media: renders using offline slate for that side.

## Acceptance criteria

1. Two butt-joined 5 s clips each with ≥2 s unused tail/head handles → Cmd+T yields centered 0.5 s dissolve; neither clip's content start/end changes beyond handle reveal; single undo restores.
2. Same action with zero handles → refusal toast, no document change.
3. Dragging dissolve from 0.5→1.5 s consumes handles symmetrically; export matches preview frame-for-frame at 5 sample points (golden test).
4. Audio crossfade curve equals constant-power reference within ±0.5 dB at midpoint.

## Out of scope (v1)

Custom/user-authored transitions, transition templates marketplace, warp/glitch GPU-heavy families, morph/cut-detection AI, 3D transitions.

## Changelog

- v0.1 — Initial draft.
