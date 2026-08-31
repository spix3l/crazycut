# Feature Spec — Area Tracking

> Status: Draft v0.5 · Owner: @steve · Last updated: 2026-08-31
> Requirements prefix: **TRK** · Rendering: `01-architecture.md` §7 · Model: `02-data-model.md` §5
> Transform: `03-features/effects.md` (**FX-9**) · Keyframes: `03-features/text-keyframes.md` (**KEY**)
> Analysis-pass precedent: `03-features/ai-assist.md` (**AI-18–22**)

## Summary

Draw a rectangle over something in the footage, run a tracking pass, and pin an asset to the
result. The region's motion is solved once as a per-frame homography and stored in the
document; from then on an image or video clip can be glued to it, following translation,
scale, rotation and perspective.

The driving case: Dev drops a meme face onto a character in a clip and it stays on the face
for the whole shot, including as the head turns — work that today means keyframing position
and scale by hand, frame by frame.

Tracking is an **explicit analysis pass**, never a render-time computation. That is what keeps
`00-product-overview.md` pillar 3 ("WYSIWYG, guaranteed by construction") true: preview and
export read the same baked path out of the document, so they cannot disagree.

## User stories

- As Dev, I box a character's face, hit Track, and drop a PNG on it that stays put for the shot.
- As Maya, the track slips halfway through a whipe pan, so I scrub to the bad frame, drag the
  box back onto the subject, and re-track forward from there.
- As Sam, I pin a screenshot to a laptop screen filmed at an angle and it sits in the screen's
  plane rather than floating flat on top of it.
- As Dev, I want to see at a glance where the track got unreliable, without scrubbing the
  whole clip to find it.
- As Maya, one shot has two people in it, so I box both faces and drop a different image on
  each without splitting the clip or tracking it twice over.

## Non-goals (v1)

- **No face or object detection.** The user draws the box. No bundled or downloaded model —
  tracking works offline with no first-use download, unlike transcription (**AI-19**).
- **No occlusion recovery.** When the subject is hidden the track holds its last good pose and
  reports low confidence; it does not re-acquire on its own.
- **No solving several regions in one pass.** A clip may carry any number of tracked regions
  (**TRK-27**), but each is its own solve and its own job; the solver is never asked for more
  than one quad at a time.
- **No tracked masks or tracked blur-island.** Driving **FX-8** from a tracker is the obvious
  next feature and is deliberately left out; see *Out of scope*.
- **No tracker in `.cctemplate`.** Templates carry clips, and a tracker is scoped to media a
  template cannot guarantee is present (`02-data-model.md` §12).
- **No graph editor for the solved path.** Corrections are made on the canvas, not in curves.

## Functional requirements

### Region and entry
- **TRK-1** The region tool is armed from either **Clip → Track Region** (⇧⌘T) or the *Draw
  region* control in the inspector's **Track** tab, which appears for a clip that has source
  pixels to solve against or is already pinned. A drawing tool is something the user reaches for
  while looking at the picture, so it does not live only behind a panel. The tool is mutually
  exclusive with the transform gizmo (**TXT-6**): arming it takes the transform handles off the
  frame, so a drag is never ambiguous about which tool it meant.
- **TRK-2** With the tool armed the user drags a rectangle on the monitor. The rectangle is
  stored as a **quad** (four corners, `TL/TR/BR/BL`) in **source pixels** of the tracked media,
  so it is independent of preview size, sequence resolution and the clip's own transform.
- **TRK-3** The tracked range defaults to the clip's full duration and is adjustable to any
  sub-range. Range endpoints are clip-local rational times (`02-data-model.md` §2).
- **TRK-4** A region smaller than 16×16 source px, or one that falls outside the source frame,
  is rejected **with a message naming the reason**, shown in the Track tab. A refusal the user
  cannot see is indistinguishable from a tool that does nothing.

### Solve
- **TRK-5** The solve runs in the **export worker process** as a `track` job over the existing
  JSON-lines protocol (`01-architecture.md` §8), exactly as transcription does (**AI-20**). It
  reports progress with an ETA and a cancel affordance in the export queue's visual language,
  and is **non-modal — editing continues throughout**.
- **TRK-6** Per frame the solver tracks feature points inside the current quad, rejects them by
  forward-backward consistency, and fits a homography by RANSAC over the survivors. The quad is
  carried forward through that homography. Features are re-seeded when the inlier count falls
  below threshold.
- **TRK-7** Analysis runs through the engine's own decoder, not a second decoding stack, at the
  source's own width capped at 1280 px. Solved quads are scaled back to full source pixels
  before storage, so the analysis width changes cost and accuracy but never the coordinate space
  of the result.
  - The solver must be told the media's **native** width, because that is what the drawn region
    is expressed in. Assuming it equals the analysis width is a silent, total failure: the
    region lands elsewhere in the analysis frame and the solved path moves at
    `analysisWidth / sourceWidth` of the true rate, so the overlay trails the subject.
  - Analysing *below* the source width costs real accuracy — halving it lost a third of the
    tracked travel on the test fixture — which is why the default follows the source rather than
    a fixed number.
- **TRK-8** Each sample carries a **confidence** in 0…1 derived from the inlier ratio. When a
  frame solves below threshold the quad **holds its last good pose** and records low
  confidence. The quad never collapses, inverts or leaves the frame as a result of a failed
  solve.
- **TRK-9** **Determinism.** The same media, quad, range, analysis width and algorithm version
  produce a bit-identical path. No wall-clock, no thread-count dependence, no RNG without a
  fixed seed. This is the tracking counterpart of **KEY-9**.
- **TRK-10** Cancelling mid-solve leaves the document byte-identical to before the run and
  writes no partial artifact.
- **TRK-11** **Re-track from the playhead.** The user drags the quad back onto the subject at
  any frame and re-solves forward from there, keeping samples before that frame. This is one
  undoable edit, following **CAP-7a**.
- **TRK-12** Tracking is optional at build time (`CC_WITH_TRACKING`). A build without it reports
  "not built with tracking support" and leaves the rest of the editor unaffected, mirroring how
  transcription degrades.

### Storage
- **TRK-13** Trackers live in a new top-level `trackers[]` array in the document
  (`02-data-model.md` §5). This stays within `crazycut/project@1`: unknown fields already
  round-trip verbatim (§9), so older builds preserve trackers rather than dropping them, and no
  migration is needed.
- **TRK-14** The solved path is stored **packed** — a flat array of eight numbers per sample,
  rounded to three decimals — alongside the sample rate, not as keyframe objects. At solve time
  it is **uniformly decimated**: the solver keeps every *n*th sample for the largest whole *n*
  that divides the span exactly and whose linear reconstruction stays within a quarter of a
  pixel, and stores the reduced rate. A locked-off shot therefore collapses to a handful of
  samples while a moving one keeps every frame.
  - Decimation is uniform, and only by divisors of the span, because the path is addressed by
    **index** at a fixed rate. A variable-spaced simplification would store fewer samples still,
    but every sample after an uneven gap would then sit at the wrong time.
- **TRK-15** Installing, re-solving or deleting a track is a **single undoable command**
  carrying the whole path, and must stay inside the 50 ms undo/redo commit budget
  (`01-architecture.md` §12).
- **TRK-16** A malformed tracker is quarantined into the repair report on load, not thrown:
  wrong quad arity, a `path` length not divisible by eight, a `confidence` length that does not
  match, or times outside the clip. Valid siblings survive.

### Pinning
- **TRK-17** Any visual clip can be pinned to a tracker. The pin is stored on the clip, in the
  same generated-spec style as `extra.clipAnim` (**TXT-10**): `transform.corners` is *generated*
  from the tracker and **rebuilt from scratch** whenever the tracker, the pin, or the tracked
  clip's own transform changes. Nothing is ever patched in place, which is why a re-solve
  cannot leave stale keys behind.
  - The cost, stated plainly: a moving pin stores the path twice — once as the tracker's packed
    samples, once as generated corner keyframes. Resolving the pin inside the compositor instead
    would avoid that, at the price of teaching the renderer to map one clip's source pixels
    through another clip's placement. Generating keeps the engine's contract unchanged and makes
    preview/export agreement structural rather than argued. Decimation (**TRK-14**) bounds the
    duplicate, and a pin that never moves collapses to a single static quad.
- **TRK-18** Pin modes, all decoded from the same solved homography:

  | Mode | Follows |
  |---|---|
  | `position` | centre only |
  | `positionScale` | centre + uniform scale |
  | `positionScaleRotation` | centre + uniform scale + roll |
  | `cornerPin` | the full quad, including perspective |

  The simpler modes exist because they discard the noisiest components of a solve; a jittery
  track is usually usable in `positionScale` when it is not in `cornerPin`.
- **TRK-19** Pinning **moves** the overlay onto the region: in `cornerPin` it adopts the
  tracked quad outright, which is the point of dropping an image onto a face. The simpler
  modes keep the clip's own shape and take only the components their name lists. Any
  subsequent nudge is stored on the pin, so it is preserved for the whole track and survives
  a re-solve rather than being flattened into the generated keyframes.
- **TRK-20** `cornerPin` cannot be expressed by **FX-9**'s transform, which carries a single
  uniform scale. It is therefore carried by a **`corners` parameter** on the clip transform,
  in sequence pixels, which **supersedes** position/scale/rotation/anchor when present. Like
  every other transform parameter it is keyframeable and is evaluated by the shared evaluator,
  so it interpolates and behaves identically in preview and export.
- **TRK-21** **Bake to keyframes** converts a pin into ordinary keyframes on the clip and
  removes the pin, so a user can leave the tracking system entirely and hand-edit the result.
  Unpinning without baking restores the clip's pre-pin pose.
- **TRK-22** Deleting a tracker, or relinking/removing the media it was solved against,
  unpins its clips and reports it. It never leaves a clip referencing a tracker that is gone.
- **TRK-26** **Replace with image** is one action: pick a picture and it is imported, placed on
  the first free video track above the tracked clip for exactly the solved range, and pinned
  corner-pin. Its file dialog offers exactly the importer's own image formats, SVG included —
  a dialog that offers formats the importer refuses, or hides ones it accepts, is wrong in both
  directions — as a single undo step. Assembling that by hand takes six steps and requires
  knowing which tracker belongs to which clip, which is enough friction that the feature would
  go unused. A free track above is reused rather than adding one per region.
- **TRK-27** **A clip carries any number of tracked regions.** Dragging a box on the picture
  always creates a *new* region and solves it — including over an existing region, so two
  overlapping subjects can each be tracked. Correcting an existing one is the corner drag of
  **TRK-11**; moving one whole is its **centre grip**, not its interior. An interior that
  swallowed drags made a busy frame undrawable: with three or four regions covering the picture
  there was nowhere left to press, and the next box moved a region instead of tracking anything.
  A press that never becomes a drag selects the region under it. Regions are independent: each
  solves as its own job, is pinned, re-tracked and deleted on its own, and one clip can drive a
  face overlay and a logo overlay at once.
  - Exactly one region is **active** at a time — the one the canvas handles, the Track tab's
    readout and **TRK-26** act on. It follows the most recent solve and is re-pointed by
    clicking a region on the monitor or picking one in the Track tab. Active-ness is session
    state, not document state: it is a selection, and nothing about the project depends on it.
  - Regions are named by their **order on the clip** — "Region 1", "Region 2" — until the user
    renames one by double-clicking its row, which stores a `name` on the tracker. Blank clears
    it back to the number, so the derived name is always underneath and there is nothing to
    migrate: an unnamed region writes no `name` at all. A re-solve keeps the name, which the
    worker's payload knows nothing about. "Region 3" stops meaning anything once three of them
    are faces.
  - A region reports **what was dropped on it** (**TRK-26**): the Track tab's row carries the
    pinned picture's file name, and the active region's readout adds its pixel size, whether it
    came from an SVG, and which track it landed on, with *Select* and *Remove*. Before this the
    only evidence an image had been placed was the picture itself.
  - The timeline's confidence stripe (**TRK-8**) is the union of every region's weak spans, so
    one region drifting is never hidden by another solving cleanly over the same seconds.

### Render
- **TRK-23** A pinned clip renders through the **shared compositor** used by both preview and
  export. `cornerPin` adds a projective warp path to the rasterizer; the other modes reuse the
  existing transform path unchanged.
- **TRK-24** A `corners` parameter is a non-identity transform and therefore **disqualifies a
  clip from the export passthrough fast path**, exactly as effects and transforms already do.
  This is a real cost and is called out here so it is not mistaken for a regression.
- **TRK-25** A `corners` quad that is degenerate (zero area, or self-intersecting) renders
  nothing for that frame rather than producing undefined pixels.

## UX notes

- **The tracked region is drawn whenever its clip is selected, not only while the tool is
  armed**, and it follows the subject as the playhead moves — through playback as well as
  scrubbing. It is feedback of last resort, so it steps aside once an overlay is pinned to it:
  from then on that overlay is the evidence the track works, and an outline drawn over the
  result is only clutter. Arming the tool brings it back, because then it is a control again. Watching the outline stay on the subject is the whole evidence that a solve is
  good, and it is the only feedback there is before an image is attached to it. Selecting a
  pinned overlay shows the region it sits on, rather than nothing.
- Armed, the outline gains draggable corners and the tool takes pointer input; disarmed, it is a
  readout and claims no pointers. A successful solve disarms the tool, so the user lands on a
  result rather than in drawing mode.
- The playhead is published on its own throttled channel, so this reads `playheadNotifier`
  directly. Anything that rebuilds only on the controller's listeners does not follow a scrub.
- After a solve the canvas draws a **motion trail** of the quad's centre across the tracked
  range, so the shape of the move is legible without scrubbing. Only the **active** region draws
  one: three trails at once is a plate of spaghetti, not a readout.
- The active region's handles are its four corners plus a **centre grip**; everywhere else on
  the picture, including inside a region, is drawing surface. A click selects, a drag draws.
- A clip's other regions are drawn thin and faded, with no handles. That is enough to see they
  are there and where to click to switch to one, without competing with the region in hand. The
  Track tab lists them, marks the active one, and its draw button reads *Draw another region…*
  once one exists — the affordance for the second region has to be visible from the first.
- Where the solve is untrustworthy the region outline turns amber on the canvas, the Track tab
  reports the confidence at the playhead and how many weak spans there are, and an **amber
  stripe along the timeline clip** marks where they fall — on the tracked clip and on anything
  pinned to it. Finding a drift should not mean watching the whole clip.
- Tracking progress uses the export queue's cards, progress bar and ETA. Nothing is modal.
- The inspector's **Track** tab carries: draw/adjust region, solve progress with cancel, sample
  count and confidence readout, pin target, pin mode, an arrow pad for nudging the overlay off
  the region (Shift for ten pixels, with a reset), *Bake*, *Unpin* and *Delete region*.
  Re-tracking is a canvas gesture — drag a corner and it re-solves forward from that frame.
  Regions are listed with their pinned picture underneath the name, and renamed in place by
  double-clicking, the same gesture that renames a timeline track.
  The pin picker names its options *clip · region*, because one clip can offer several.
- **A solve in flight is visible from the moment the box is released**: the drawn rectangle stays
  on screen, faded and without handles, and the Track tab shows progress, ETA and cancel. The
  first solve has no tracker in the document yet, so the region is **named before it is solved**
  and made active — the job is keyed on that id, which is what makes the run the user is waiting
  on findable. A per-clip lookup remains as the fallback, but it cannot tell two regions of one
  clip apart while both are in flight.

## Edge cases

- **Subject leaves frame** — quad holds, confidence drops, warning stripe appears. No crash, no
  collapse.
- **Cut inside the tracked range** — the solve will fail across the cut and hold. Tracking
  across a hard cut is user error; the confidence display is the feedback.
- **Clip trimmed after tracking** — the tracker's range is clamped to the new duration; samples
  beyond it are dropped, matching the keyframe trimming rule in **TXT**/**KEY**.
- **Clip speed changed** — tracker sample times rescale proportionally, as keyframe times do.
- **Reversed clip** — the path is read back to front; it is not re-solved.
- **Sequence resolution changed** — the path is in source pixels, so it is unaffected; only the
  derived `corners` in sequence pixels change, and they are derived per render.
- **Still image or single-frame media** — tracking is refused; there is no motion to solve.
- **Media relinked to a different file** — the tracker is invalidated and its clips unpinned
  (**TRK-22**), because a path solved against other pixels is meaningless.

## Performance

- The solve is decode-bound. The engine decodes in software today
  (`07-capability-matrix.md`), and a forward pass at reduced width is roughly the cost of a
  proxy transcode of the same range. It runs out of process, so it never competes with preview
  for the render thread.
- Path storage is small but not free: a 30 s shot at 30 fps is about 900 samples ≈ 55 KB of
  JSON before decimation, and a moving pin stores it a second time as generated keyframes
  (**TRK-17**). This counts against the "open a 500-clip project in under 2 s" budget
  (`01-architecture.md` §12); decimation (**TRK-14**) is what keeps typical projects well clear
  of it. A project with dozens of long, genuinely moving tracks is the case to watch.
- The projective warp iterates only the bounding box of the quad, not the whole canvas.
- A quad equal to the layer's plain rectangle must render **bit-identically** to the
  non-corner path, so pinning cannot silently degrade the common case.

## Acceptance criteria

1. Boxing a moving, rotating subject and hitting Track reports monotonic progress with an ETA,
   leaves the editor responsive throughout, and can be cancelled mid-run leaving the document
   byte-identical (**TRK-5**, **TRK-10**).
2. An image pinned in `cornerPin` mode stays on the subject through translation, scale, roll
   and perspective; scrubbing to any frame lands it in the same place playback does
   (**TRK-18**, **TRK-20**).
3. Saving, closing and reopening preserves the track and the pin, and the project still opens
   inside its budget (**TRK-13**, §Performance).
4. Undo after a solve removes it in one step; redo restores it in one step, within 50 ms
   (**TRK-15**).
5. Exported frames of a pinned clip are **bit-identical** to `cc_render_frame_rgba` at the same
   timestamps (**TRK-23**, **TRK-24**).
6. Tracking a shot where the subject leaves frame degrades to a held quad with a visible
   warning stripe, and never collapses or crashes (**TRK-8**).
7. Re-solving the same region twice produces a bit-identical path (**TRK-9**).
8. A document with a corrupt tracker loads with the tracker quarantined and every other
   tracker, clip and effect intact (**TRK-16**).
9. Boxing two subjects in one clip leaves two independent regions: each solves, each takes its
   own pinned overlay, correcting one does not disturb the other, and deleting one leaves the
   other and its pin intact (**TRK-27**).
10. On a clip already carrying three regions, dragging a box across them adds a fourth rather
    than moving one of them, and a renamed region keeps its name through a re-solve, a save and
    a reload (**TRK-27**).

## Out of scope

Face/subject detection and auto-reframe (`03-features/shorts.md` non-goals), tracked masks and
tracked blur-island driving **FX-8**, motion-tracked text (`03-features/text-keyframes.md`),
motion-tracked captions (`03-features/captions.md`), planar surface *replacement* with
relighting, stabilisation, 3D camera solve, solving several regions in one pass, and any
network- or model-backed tracker.

## Changelog

- v0.5 — **TRK-27** regions are drawn anywhere, including over each other: moving one is its
  centre grip rather than its interior, which is what made a fourth region undrawable. Regions
  can be renamed (stored `name`, blank returns to the number), report the picture pinned to
  them, and **TRK-26**'s file dialog follows the importer's own image formats (SVG included).
- v0.4 — **TRK-27** any number of tracked regions per clip: drawing on empty picture adds one,
  regions are named by their order on the clip, one is active at a time, and the confidence
  stripe unions them.
- v0.3 — **TRK-26** replace-with-image in one action; the tracked region is a live readout
  whenever its clip is selected and follows the playhead; a solve disarms the tool.
- v0.2 — Menu-bar entry and shortcut for the region tool (**TRK-1**); refusals name their
  reason (**TRK-4**); timeline confidence stripe; nudge control; in-flight solves visible before
  the tracker exists.
- v0.1 — Initial draft.
