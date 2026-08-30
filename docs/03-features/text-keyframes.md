# Feature Spec — Text, Images & Keyframe Animation

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-21
> Requirements prefix: **TXT** (text) / **KEY** (keyframes) · Storage: `02-data-model.md` §6

## Summary

Text clips and images live on any video track with free duration. A single keyframe system animates properties across effects, transforms, text, and audio — one mental model everywhere: *diamond in, diamond out*.

## User stories

- As Dev, I slap an animated caption preset on a clip and tweak the words — done in 10 seconds.
- As Maya, I animate a logo sliding in with fade over the intro.
- As Sam, I punch into my screen recording by keyframing scale/position on two keyframes.

---

## Part 1 — Text

### Functional requirements

- **TXT-1** Text clips: created via toolbar "T" button, drag from Text gallery, or context menu; placed at playhead on selected/topmost video track; free duration; default 5 s.
- **TXT-2** Content: multi-line string (`\n`), emoji supported via platform stack. Single style per clip v1 (per-line styling v1.5).
- **TXT-3** Styling params: font family (system fonts enumerated + 6 bundled open fonts), size (px @1080-height-normalized), weight, color, letter spacing, line height, alignment (L/C/R), stroke (width/color), shadow (blur/offset/color/opacity), background box (color/padding/corner radius, "auto-width to text").
- **TXT-4** Presets gallery (~20): Title, Subtitle, Lower third, Caption bar, Meme (Impact-style), Quote, Callout label… Each = style + default animation; fully editable after apply.
- **TXT-5** Text animates through the shared clip-animation system (TXT-10), not through a text-only preset list: one Enter/Leave picker in the Transform inspector, plus the full-length motion slot. Text adds the looks only it can play — **Typewriter** on Enter (per-character reveal produced by the rasterizer) and **Blink** as motion — and the Enter duration is the typing speed. There were two entry points for the same job; there is now one.
  - *History*: text clips used to carry their own preset id on `text.animation` and bake their own keyframes. Projects saved that way migrate at load: the preset becomes an entry (or, for blink, a motion) on the generic spec, and the baked keys are regenerated from it. The old ids named the side the text came **from** while the shared ones name the direction it **travels**, so `slideLeft` migrates to `slideRight` and back. A legacy typewriter kept its fixed 24 characters/second by taking the entry duration its own string used to need.
- **TXT-6** On-canvas editing: double-click text in preview → inline edit box matching final typography; drag moves position (writes transform position); corner handles scale; rotation handle rotates. Safe-area guides toggle helps keep captions platform-friendly.
  - A click targets the front-most image it actually lands on, not whatever is selected; the current target's handles and rotation knob still win, since they sit outside its rect. With two images on screen, targeting the selection alone meant dragging one moved the other.
  - While a gesture is open the monitor renders at `EditorController.maxLiveEditPreviewWidth` and pushes one document per completed frame instead of on a timer. A full-resolution composite of a real project measures 30-110 ms; at that latency the image trails the handles far enough to read as the gizmo being misaligned with its own clip.
  - *Implemented for image and video clips* (`canvas_gizmo.dart`): drag to move, eight handles to resize, a knob to rotate, Alt to resize about the centre, Shift to snap rotation to 15°. Scale is uniform — `ClipTransform` and the engine's `CompositedLayer` carry one `scale`, so edge handles resize proportionally. The handle rect mirrors `rasterizeLayer()` via `state/canvas_geometry.dart`. Text clips are still inspector-only: their texture is a Dart raster with no asset dimensions to measure.
- **TXT-7** Text renders through cached glyph atlases (CoreText/DirectWrite) composited as a texture — transform/effect/keyframe machinery identical to images (`01-architecture.md` §7).

### Acceptance criteria
1. Apply "Caption" preset → type → plays with animation; changing font re-renders next frame without cache artifacts.
2. Typewriter exports identically to preview (deterministic per-frame reveal, golden test), at whatever speed the entry duration sets.
3. 50 simultaneous text clips preview ≥ 30 fps on ref hardware (atlas caching verified).

---

## Part 2 — Images & stills

- **TXT-8** Image assets import per IMP spec; dropped to timeline they become clips with free duration (default 5 s or fit-to-drop-span).
- **TXT-9** Ken Burns convenience: context menu "Animate" offers zoom-in/zoom-out/pan presets that generate transform keyframes across the clip (editable afterwards like any keyframes).
- **TXT-10** Explicit entry/leave animations for every visual clip (text, image, and video): Fade, Pop, Rise, Slide (4 directions), Blur and Wipe (4 directions), each with its own duration, picked per edge in the Transform inspector or the clip context menu. Text clips additionally offer Typewriter on entry. Audio-only clips do not receive visual edge animation.
  - Continuous motion is per clip kind: Ken Burns on images, Blink on text, none on video. The picker only ever lists what that clip can actually play.
  - A typewriter writes no keyframes at all: the reveal happens in the rasterizer, which types the string over the entry duration. The exporter bakes one texture per *distinct* reveal (sampled at 60/s, never more than one per character) and sends the resulting characters-per-second to the worker, so the frame the worker picks is the frame the preview showed.
  - The whole animation is *generated* from a shared spec on the clip (`extra.clipAnim`: motion, entry, leave, resting pose, owned effect ids) and rebuilt from scratch on every change, which is what makes a preset removable and lets an entry land on the Ken Burns curve instead of clobbering it. Older `extra.imageAnim` payloads migrate on load.
  - Fade/Pop/Slide are transform keyframes; Blur and Wipe are managed `gaussianBlur`/`crop` instances with keyed params. Both are evaluated by the shared compositor, so preview and export agree and no engine change was needed.
  - The resting pose is stored in the spec and read back from it, so a drag on the monitor moves the pose and the animation replays around it. When it has to be re-derived (a project whose spec predates it) it is read from the middle of the clip, never from t=0 — that is exactly where an entry animation parks its start value.
  - Only x/y/scale/opacity and the clip's own managed effects are ever rewritten — rotation, user effects and hand-authored keys on other params survive a rebuild and a clear.

---

## Part 3 — Keyframe system (shared)

### Model
- **KEY-1** Animatable property registry (per effect/clip type) declares: id, value type (float / point / color / enum-as-float), range, default, unit. Registry is code-defined and versioned with schema.
- **KEY-2** Keyframe: `{ t (clip-local rational time), v (value), interp }`. Interpolation v1: `linear`, `easeIn`, `easeOut`, `easeInOut`, `hold`. Values outside keyframed span hold nearest keyframe (no extrapolation v1).
- **KEY-3** Any param can mix: static-only, or N keyframes. First keyframe creation converts current static value into the first key (never loses user's value).

### UI
- **KEY-4** Inspector: every animatable row ends in a ◆ toggle. Behavior: click ◆ at playhead → adds/updates keyframe with current value; ◆ lit when a key exists at playhead; right-click ◆ → context menu (previous/next key, delete key, clear all).
- **KEY-5** Clip mini-editor: selecting a clip shows a keyframe lane under it in the timeline (expandable): diamonds per property color-coded, draggable horizontally (time), value edits stay in inspector. Two-keyframe spans render as a connecting line.
- **KEY-6** Graph editor (curve handles) is **v1.5**; v1 ships interpolation presets only. Design reserves lane space for it.
- **KEY-7** Copy keyframes (per property or whole clip) / paste at playhead; alt-drag duplicates a key.
- **KEY-8** Preview scrubbing over keyframed span evaluates live; playback cost of animated params must not break realtime budget for ≤ 3 simultaneously animated layers on ref hardware.

### Determinism
- **KEY-9** Evaluation is pure: `value(param, t)` depends only on keys + interp; same inputs ⇒ bit-identical output between preview and export (enforced by golden tests sampling 10 frames/span).

### Acceptance criteria
1. Keyframe opacity 100→0 across 1 s → export matches preview at t=0.25/0.5/0.75 exactly.
2. `hold` interpolation shows stepped change (no tweening) in both preview/export.
3. Deleting all keyframes returns param to static mode retaining last value; undo restores keys.

## Edge cases

- Keyframe times clamped to `[0, clip.duration]`; trimming a clip keeps keys' relative positions but clamps/drops those beyond new duration (undoable, toast explains once).
- Speed change rescales keyframe times proportionally (content timing preserved relative to source).
- Font missing at open (uninstalled): fallback font + badge on affected clips; relink-font dialog lists substitutions.
- Emoji-only strings render at fixed metrics; no crash on empty string (clip renders nothing but stays editable).

## Out of scope (v1)

Bezier custom curves/graph editor [v1.5], rich text/multi-style, text-on-path, shape layers, auto-captions from speech [v1.5 candidate], per-character 3D.

Motion-tracked *text* remains out of scope. Area tracking itself is specced in
`03-features/tracking.md` (**TRK**) and pins image/video clips only; pinning a text clip needs
the text model to gain a size in the document (**FX-15**) and is a separate change.

## Changelog

- v0.1 — Initial draft.
