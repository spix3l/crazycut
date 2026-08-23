# Feature Spec — Reusable Templates

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-23
> Requirements prefix: **TPL** · Model: `02-data-model.md` §5/§12 · Transitions: `03-features/transitions.md`

## Summary

A template is a pre-built chunk of timeline — clips, their effects, text, transitions between them — saved once and dropped into any project afterwards. Insertion asks only for the parts that change: the section title, the background shot, how long it holds. The chunk keeps its own internal transitions, and carries an **edge transition** spec describing how it should join whatever it lands between.

The driving case: a "Section announcement" — a 3 s title card over a looping background with a dissolve in and out. Building it once and re-using it per chapter should take a name and one text field, not a re-edit.

## User stories

- As Dev, I build a chapter bumper once, save it as a template, and announce eight sections by typing eight titles.
- As Maya, I keep a "lower third" template whose background clip is swappable per project.
- As Sam, I want my bumper to dissolve into the footage on both sides without adding transitions by hand each time.

## Functional requirements

### Library
- **TPL-1** Templates live as standalone `.cctemplate` JSON files in `~/Documents/CrazyCut/Templates` (Windows: `%USERPROFILE%\Documents\CrazyCut\Templates`), one file per template, visible from every project. The folder is created on first save; a missing or unreadable folder yields an empty library, never an error dialog.
- **TPL-2** The Templates tab of the left rail lists every template with name, category, duration and slot count, searchable by name/category/description. Per-template actions: Insert at playhead, Rename, Duplicate, Reveal in folder, Delete.
- **TPL-3** A file that fails to parse is skipped and reported once in the panel ("2 templates could not be read"), never crashing the list.

### Authoring
- **TPL-4** "Save selection as template…" (⌘⇧T, timeline context menu) captures the selected clips. Capture stores: clip payloads with times **relative to the selection's first clip**, lane offsets rather than track ids, every transition whose both sides are inside the selection, and a media reference (hash, name, path, probe) per asset used.
- **TPL-5** Capture proposes **slots** — the parts an insert may change:
  | Slot kind | Proposed for | Value on insert |
  |---|---|---|
  | `text` | every text clip | the clip's text content |
  | `media` | every clip with media | a project asset to swap in |
  | `duration` | the template as a whole | total seconds (proportional retime) |
  Each proposal has an editable label and can be dropped before saving. Text slots are proposed enabled, media slots disabled, the duration slot enabled.
- **TPL-6** The save dialog also sets name, description, category and the two edge transitions (§ Edge transitions). Saving is atomic (temp file + rename) like project writes.

### Transitions
- **TPL-7** *Internal* transitions are stored verbatim with their geometry (`duration`, `alignment`, `aExtend`, `bExtend`). Insertion re-creates them directly from the stored overlap — it does not re-derive handles — so a template renders exactly as authored.
- **TPL-8** *Edge* transitions are a spec, not an entity: `{ enabled, type, duration, easing }` for the head and the tail of the template. On insert, each enabled edge runs the normal `addTransition` path (TRA-2) against the neighbouring clip on the base lane, so handle rules, alignment fallback and refusals behave exactly as a hand-made transition.
- **TPL-9** An edge with no neighbour (template at the sequence start/end) is skipped silently. An edge whose neighbour has no handles is skipped with a warning naming the reason, and the insert still completes — never refused wholesale.
- **TPL-10** Edge transition type/duration can be overridden per insert without editing the template.

### Insertion
- **TPL-11** Insert places the template on the base video lane (default: the lane the template was authored on, mapped to the topmost unlocked video track) at the playhead, in `insert` (ripple) or `overwrite` mode. Extra lanes are mapped by relative offset and created when missing.
- **TPL-12** Media references resolve in order: (1) asset already in the project with the same content hash; (2) file still at the recorded path → imported into the project; (3) otherwise an offline asset carrying the recorded probe data, so the standard relink flow (IMP-15) can fix it later. Insertion never blocks on missing media.
- **TPL-13** Slot values apply during insertion, inside the same edit: text slots rewrite the clip's content, media slots repoint `mediaId` (clamping `sourceIn`/`duration` to the new source), the duration slot scales every clip's start and duration proportionally.
- **TPL-14** One insert — media resolution, clips, internal transitions, slot values and both edges — is a **single undo step**.
- **TPL-15** Inserted clips become the selection, so the next edit acts on the chunk.

## UX notes

- Left rail tabs: **Media | Templates**. The Templates tab keeps the same card metaphor; a card shows name, duration badge and slot count.
- The insert dialog shows one field per enabled slot in the author's order, then the two edge pickers, then mode. Enter inserts.
- Warnings from an insert (skipped edge, clamped duration, offline media) appear once, listed in the panel's status line rather than as a modal.

## Edge cases

- Template authored at a different fps/frame size: times are rational and resolution-independent, so insertion is exact; a frame-size mismatch is noted as a warning, not blocked.
- Selection spanning a transition where only one side is selected: that transition is not captured (the geometry it owns is trimmed back on insert by the standard sanitize pass).
- Duration slot shrinking a chunk below one frame per clip: clamped at one frame, warned.
- Duration slot and keyframes: clip-local keyframe times are **not** rescaled, so a stretched chunk keeps its authored animation timing at the head of each clip. Stretching warns about it; rescaling animation is a v1.5 evolution.
- Duration slot growing past the media a clip actually has: clamped to the available source, warned.
- Deleting a template file while the panel is open: the next refresh drops it; an insert already in flight completes.

## Acceptance criteria

1. Capture two clips joined by a 0.5 s dissolve plus a text clip on V2 → insert into an empty project → geometry, dissolve and text match the source frame-for-frame; one undo removes everything.
2. Insert with a text slot value → the inserted text clip carries it, the template file is unchanged.
3. Insert between two clips with ≥1 s handles, both edges enabled → two transitions exist against the neighbours with the requested type/duration.
4. Same insert where the left neighbour has no handles → left edge skipped with a warning, right edge still created, insert completes.
5. Insert whose media is absent from disk → clips land offline and relink repairs them.

## Out of scope (v1)

Template marketplace/sharing, nested templates, per-slot validation rules, animated preview thumbnails, templates stored inside the project document.

## Changelog

- v0.1 — Initial draft.
