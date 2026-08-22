# Feature Spec — Timeline & Editing

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-21
> Requirements prefix: **TIM** · Model: `02-data-model.md` · Shortcuts: `04-ui-ux.md` §7

## Summary

A real multi-track NLE timeline that feels weightless: unlimited video/audio tracks, precise trimming (roll/slip/slide), ripple when asked, snapping everywhere, JKL shuttle, and an undo system that never loses work. This is the heart of the product; every interaction here has a latency budget.

## User stories

- As Maya, I cut a 12-minute interview into a 8-minute story with ripple deletes and it takes minutes, not hours.
- As Dev, I drag clips around fast and sloppy — snapping makes everything land clean.
- As Sam, I zoom from whole-project view to frame-level trim without the UI stuttering.

## Functional requirements

### Structure
- **TIM-1** Unlimited tracks: video tracks stack bottom→top (later renders above), audio tracks below the video divider. Add/remove/reorder (drag), rename (double-click).
- **TIM-2** Track controls per track header: mute, solo (audio), hide (video), lock (no edits), height slider (S/M/L). Solo on audio = all other audio muted.
- **TIM-3** Clips: move within/between compatible tracks (video→video, audio→audio) by drag; Alt-drag duplicates; linked A/V groups move together unless Alt held (see `02-data-model.md` `linkedGroup`).
- **TIM-4** Placement model: free positioning with snapping; manual drags can never create overlaps on the same track — overlapping drop pushes/inserts neighbors (magnetic push) or is prevented at drop with rubber-band feedback (whichever requires no timing surprises: default = push right on same track).
- **TIM-5** Three-track drop targeting while dragging from pool: insert (ripple), overwrite, append — chosen by modifier keys and previewed live (ghost + affected region highlight).

### Trimming
- **TIM-6** Trim types: edge trim (drag clip head/tail), **roll** (adjacent cut point moves, total span fixed), **slip** (Alt-drag body: content shifts inside fixed span), **slide** (Cmd-drag body: clip moves between neighbors, neighbors compensate).
- **TIM-7** Trim limits show media handles: hitting source start/end stops the trim with resistance haptics-equivalent (visual bump); timecode tooltip shows exact delta frames.
- **TIM-8** Numeric trim: selected clip edges editable in inspector (frame-exact entry).
- **TIM-9** Ripple delete (Shift+Del) closes gap pulling all later clips on all tracks? No — ripple pulls later clips on **affected tracks only** (tracks the selection spans), preserving sync elsewhere; plain Delete leaves gap. Toggleable "magnetic timeline" global mode (Settings, default off) auto-closes gaps on the topmost storyline.

### Splitting, markers, navigation
- **TIM-10** Split at playhead (S): splits selected clips or all clips under playhead if none selected; linked A/V split together.
- **TIM-11** Markers: add (M) at playhead, named/colored, draggable on ruler, navigable (Shift+←/→ jumps between markers), visible as flags on ruler and clip level (clip markers v1.5).
- **TIM-12** Navigation: playhead scrub anywhere; Home/End sequence bounds; ←/→ step frame; Shift+←/→ step 1 s; PageUp/Down jump cuts under playhead; in/out points (I/O) define loop/playback range and export range default; Clear in/out (Alt+X).
- **TIM-13** Shuttle: J/L forward/backward accelerating through 1×→2×→4×→8×; K pause; K+L slow creep (¼ speed). Audio behavior per `01-architecture.md` §6.
- **TIM-14** Zoom: horizontal via pinch, Cmd+=/−, or slider; zoom-to-fit (\). Zoom is anchored to mouse pointer. Vertical: track heights per TIM-2. At high zoom, clips render filmstrip thumbnails (video) / waveforms (audio); at low zoom, representative thumbnails + duration labels.

### Snapping
- **TIM-15** Snap candidates: playhead, clip edges (all tracks), markers, in/out points, sequence start/end, whole seconds at fine zoom. Toggle magnet button + hold-Cmd bypasses temporarily. Snap indicator line highlights the winning candidate.

### Selection & clipboard
- **TIM-16** Selection: click, Shift-click add, marquee (drag empty space), Select All (Cmd+A, per track with track-header click → select track clips), invert. Selected clip outlines glow accent color.
- **TIM-17** Copy/paste (Cmd+C/V): pastes at playhead on original track(s), magnetic push. Copy also captures the primary clip's look/audio settings; Paste Settings (Alt+Cmd+V) applies compatible transform, blend, effects, and audio controls to the selected unlocked clips.
- **TIM-18** Multi-select operations apply to all selected: move, trim (each edge independently), delete, split, group ops.

### Speed (basic)
- **TIM-19** Clip speed dialog/context menu: 0.25×–4× rational presets + custom; retime affects duration (or "preserve duration" mode adjusts source range); icon + duration label update; audio pitch handling per AUD spec. Reverse checkbox (video only v1; reverse+audio unsupported → audio detached/muted automatically with notice).

### Undo/redo
- **TIM-20** Command-pattern undo (Cmd+Z / Shift+Cmd+Z), unlimited depth (memory-capped ~100 MB then oldest dropped), coalescing of continuous gestures (drags/trims commit once on release; slider changes coalesce 500 ms). Every document mutation in every feature flows through this system — no side-channel edits.
- **TIM-21** Undo restores full document state including effects/keyframes/transitions; redo survives until new edit.

### Performance
- **TIM-22** Timeline rendering virtualized: only visible clips/thumbnails drawn; 500-clip project scrolls at 60 fps on reference hardware.
- **TIM-23** Any committed edit updates engine graph < 1 frame and preview reflects it next vsync (`01-architecture.md` §9).

## UX notes

- Playhead line spans full timeline height with a grab handle in the ruler; scrubbing plays short audio ticks (scrubbing audio) by default, toggleable.
- Drop ghosts show computed final position + duration badge; invalid drops shake back.
- Locked tracks dim headers and ignore all input incl. drops.
- Context menus carry the full verb set for the target (clip/track/ruler/empty).

## Edge cases

- Trim across transition boundaries: transitions consume handles first (see TRA spec); trimming into a transition's consumed range shortens/disolves the transition with preview.
- Dragging a clip to a locked/hidden track: rejected with reason toast.
- Zero-length result (trim both edges past each other): clamps to minimum 1 frame.
- Paste when target track deleted: recreates track silently.
- Sequence end padding: playhead can park beyond last clip; exports clamp to content unless in/out set.

## Acceptance criteria

1. Ripple-delete a middle clip on V1+A1 (linked) → later clips slide left exactly one gap on those tracks; other tracks untouched; single undo reverts fully.
2. Roll trim at 29.97 fps project lands on exact frame boundaries (rational math verified vs OTIO-style reference calc in unit tests).
3. 500-clip synthetic project: scroll/zoom at 60 fps, seek p95 ≤ 100 ms, undo commit ≤ 50 ms (CI perf suite).
4. Slip a clip whose handles are exhausted → clamps at source bounds, no negative durations possible.

## Out of scope (v1)

Magnetic-only storyline model (Final Cut style), nested sequences/composites, multicam, time ramps, clip markers (v1.5), storyboard mode, replace-edit semantics beyond drop modifiers.

## Changelog

- v0.1 — Initial draft.
