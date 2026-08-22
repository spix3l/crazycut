# Feature Spec — Effects

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-21
> Requirements prefix: **FX** · Rendering: `01-architecture.md` §7 · Keyframes: `03-features/text-keyframes.md` §3

## Summary

Per-clip effect stacks covering the creator basics: color correction, blur family, transform/crop, and blend modes. Every parameter is keyframeable, every effect has a sane default that looks good with zero tweaks, and the stack applies top-to-bottom deterministically.

## User stories

- As Maya, I fix slightly underexposed b-roll in two slider moves and match shots by copying attributes.
- As Dev, I blur a background clip behind my face-cam and punch it in with animated scale.
- As Sam, I crop a screen recording to the window and add rounded focus on the cursor area (crop + transform).

## Functional requirements

### Effect stack
- **FX-1** Every video/image/text clip has an ordered effect list; order = application order (list top → applied first? **Convention: list renders top-down; item at top of list is applied first**). Reorder via drag; enable/disable per effect (checkbox); reset per effect; remove.
- **FX-2** Effects panel in inspector lists active effects + "Add effect" button opening a searchable gallery with categories and favorites (starred effects pin to top).
- **FX-3** Copy/paste effects between clips (single or whole stack); Paste Settings from TIM-17 reuses this.
- **FX-4** Effect params are animatable unless marked static; keyframe UI per `03-features/text-keyframes.md`.

### Color (category: *Color*)
| Effect | Params (defaults) |
|---|---|
| **Exposure** | stops −2…+2 (0) |
| **Contrast** | −1…+1 (0) |
| **Saturation** | 0…2 (1) |
| **Temperature** | −1 (cool) … +1 (warm) (0) |
| **Tint** | −1 (green) … +1 (magenta) (0) |
| **Fade** | 0…1 lift blacks toward white (0) |
| **Vignette** | amount 0…1, roundness, softness |

- **FX-5** All color params apply in linear-light processing when GPU pipeline allows (`01-architecture.md` §7).
- **FX-6** Filter presets ("Looks"): ~24 curated one-click looks (e.g., Punchy, Warm Film, Teal & Orange, B&W Contrast) implemented as fixed param combos on the above effects — inspectable/editable after applying (no black boxes).

### Blur (category: *Blur & Style*)
| Effect | Params |
|---|---|
| **Gaussian blur** | radius 0…100 px (sequence-resolution-relative), quality auto |
| **Box blur** | radius, iterations (perf knob) |
| **Pixelate / Mosaic** | cell size 2…128 px |
| **Sharpen** | amount 0…1 |

- **FX-7** Blur radii are defined relative to sequence height so 1080p and 4K sequences match visually.
- **FX-8** Region-limited blur (linear/ellipse mask with feather + position/scale animation) ships as **blur-island** variant of gaussian in v1 — primary use case: obscuring faces/plates. Mask params keyframeable.

### Transform (category: *Transform*)
- **FX-9** Built-in transform on every visual clip (not an added effect): position X/Y, scale %, rotation °, anchor point, opacity 0–100%, flip H/V, fit/fill/stretch framing mode for mismatched aspect.
  - Position x/y are **document** pixels. The compositor scales them into whatever canvas it is rendering (`RenderContext.positionScaleX/Y`), so a preview rendered small and the delivered frame put a clip in the same place.
  - Resampling: a layer drawn at 1:1 (text rasterized for the frame, footage at sequence size) is copied pixel for pixel; anything scaled or rotated is bilinear-filtered in premultiplied alpha. Nearest-neighbour was visibly blocky on scaled logos and text, and interpolating straight alpha put a dark fringe on every transparent edge.
  - Editable on the monitor as well as in the inspector — see TXT-6. `app/lib/state/canvas_geometry.dart` mirrors `rasterizeLayer()` so the handles land on the pixels; `app/test/canvas_gizmo_parity_test.dart` renders through the engine at several canvas sizes and asserts the two still agree.
- **FX-15** Align & distribute for the selected visual clips, in the inspector's Transform tab: 6 align actions (left/centre/right, top/middle/bottom) and 2 distribute actions (horizontal/vertical).
  - Reference frame: with several clips selected they line up against the **union of their own footprints**; with exactly one selected, against the **sequence canvas**.
  - A clip's footprint is the axis-aligned bounding box of its rotated layer rect (`rotatedBounds` in `canvas_geometry.dart`), evaluated at the playhead — position/scale/rotation are animatable, so alignment is a snapshot of the pose on screen.
  - Distribute equalises the *gaps*; the outermost two clips stay put, so it needs three or more.
  - Writes go through the same rebasing `setTransformParam` path the on-canvas gizmo uses, and the whole batch is one undo step. Text clips are excluded — they have no size in the document model.
- **FX-10** Crop effect: left/right/top/bottom % or px, feather edge option, rounded corners (radius px) — rounded corners double as image styling favorite.
- **FX-11** Drop shadow effect for images/text-on-image use: offset, blur, color, opacity.

### Blending
- **FX-12** Per-clip blend mode: Normal, Multiply, Screen, Overlay, Add, Soft Light. Applied at composite step against accumulated layers below.

### Presets & management
- **FX-13** Users can save any stack as a named user preset (stored app-local JSON, synced never in v1); factory presets read-only.
- **FX-14** Effect count guardrail: > 8 effects on one clip shows a gentle perf hint ("this may reduce playback smoothness") once, never blocks.

## UX notes

- Inspector rows: label, slider (scrubbable number), value box, keyframe diamond, reset chip. Sliders support fine-tune with Shift (×0.1), double-click resets to default.
- Adding an effect previews its default instantly; undo removes cleanly.
- Color effects show a tiny before/after split toggle in the preview while their inspector section is hovered (split line draggable).

## Edge cases

- Extreme values (saturation 0 on near-black footage, blur radius max): no NaNs/crashes; CPU fallback path matches GPU within perceptual tolerance (golden tests).
- Effects on offline clips: preserved, ignored until relinked.
- Copying a stack referencing sequence-relative sizes across resolutions: radii scale by height ratio automatically.
- Blend modes on bottom-most track: behave as Normal (nothing below).

## Acceptance criteria

1. Apply "Warm Film" look → single undo removes all constituent effects as one command.
2. Gaussian blur radius 40 at 1080p vs 4K sequence renders visually identical framing (normalized test).
3. Keyframed pixelate (cell 4→64) plays in realtime preview on ref hardware with ≤ 1 dropped frame/s.
4. CPU fallback render of a reference composition matches GPU within ΔE < 2 average (golden suite).

## Out of scope (v1)

Custom LUT import (.cube) [v1.5], curves/wheels/keyer, motion blur, optical-flow retiming, third-party plugin API, masks beyond blur-island shapes.

## Changelog

- v0.1 — Initial draft.
