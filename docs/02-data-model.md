# CrazyCut — Data Model & Project Format

> Status: Draft v0.3 · Owner: @steve · Last updated: 2026-08-30
> Companion docs: `01-architecture.md`, `03-features/*`

## 1. Principles

1. **The document is the single source of truth.** It lives in Dart, is mutated only through commands (undoable), and serializes to `.crazycut` JSON. The engine's render graph is derived and disposable.
2. **Non-destructive.** Media files are referenced, never moved, renamed, or re-encoded by editing operations.
3. **Frame-accurate math.** All times are rational numbers; no floating-point time anywhere in the model.
4. **Forward-safe.** Unknown fields are preserved on load; schema version gates migrations.

## 2. Time

- Type: rational `{ "n": int64, "d": int32 }`, `d > 0`, always normalized (gcd reduced, `d > 0`). Serialized as an object or the compact string form `"n/d"` — both accepted on load; canonical output is `"n/d"`.
- Sequence time base: sequence fps defines frame boundaries. Clip starts/durations are stored in **sequence time**; `sourceIn` is in **source time** (source fps).
- Frame snapping uses exact rational arithmetic (e.g. NTSC 30000/1001 frames are exact); UI displays timecode per sequence fps.
- Durations must be > 0 for clips/transitions; stills/text have free duration (no source limit).

## 3. Identifiers

- All entity ids are UUIDv7 strings (`time-ordered`, e.g. `"018f6d2a-…"`) generated client-side. Ids never change after creation; they survive undo/redo, copy/paste creates new ids.
- Asset identity = content hash (see §7), independent of path.

## 4. Entity overview

```
Project ─┬─ settings (sequence settings)
         ├─ media[]        (MediaAsset)
         ├─ tracks[]       (Track)
         ├─ clips[]        (Clip)          → trackId, mediaId?
         ├─ transitions[]  (Transition)    → aClipId, bClipId
         ├─ markers[]      (Marker)
         ├─ trackers[]     (Tracker)        → mediaId, sourceClipId
         └─ meta (ids, timestamps, app version)
```

- v1: exactly one sequence per project; its settings live at `project.settings`. Multi-sequence projects are a v1.5 evolution (schema reserves `sequences[]`).

## 5. Schema (v1)

Top-level:

```json
{
  "schema": "crazycut/project@1",
  "id": "018f6d2a-7c1d-7b2e-9f3a-1e2d3c4b5a6f",
  "name": "Summer recap",
  "createdAt": "2026-08-21T10:12:00Z",
  "modifiedAt": "2026-08-21T12:40:31Z",
  "appVersion": "0.1.0",
  "settings": {
    "width": 1920,
    "height": 1080,
    "fps": "60000/1001",
    "audioSampleRate": 48000,
    "background": "#000000",
    "master": {                 // master bus — AUD-10/11
      "gain": 1.0,              // linear output fader
      "limiter": true,          // safety brickwall, on by default
      "ceilingDb": -1.0         // limiter ceiling, dBFS
    }
  },
  "media": [ /* MediaAsset */ ],
  "tracks": [ /* Track, ordered bottom→top for video; top→bottom listed audio-first? see below */ ],
  "clips": [ /* Clip */ ],
  "transitions": [ /* Transition */ ],
  "markers": [ /* Marker */ ],
  "trackers": [ /* Tracker — 03-features/tracking.md */ ]
}
```

Track ordering convention: array index 0 = **bottom-most video layer**; audio tracks follow after video tracks in the same array (`kind` distinguishes). Compositing order = ascending index (later over earlier).

### MediaAsset

| Field | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `hash` | string | `"sha256:<hex>"` of full file (see §7) |
| `name` | string | display name (original filename) |
| `path` | string | last-known absolute path (relink uses hash first) |
| `type` | enum | `video` \| `audio` \| `image` |
| `duration` | time | images: omitted |
| `hasAudio` | bool | |
| `probe` | object | width, height, rotation, fps `"n/d"`, vfr bool, codec, hdr enum(`none\|hdr10\|hlg`), audio channels/layout |
| `proxyPath` | string? | set when proxy exists |
| `thumbStatus` | enum | `none\|pending\|ready\|failed` |
| `sourceKind` | enum | `file\|url`; omitted means `file` for backward compatibility |
| `remote` | object? | URL validators: `etag`, `lastModified`, `contentLength` |

For URL assets, `path` contains the normalized entered URL and `hash` remains empty. Derived cache identity uses the asset id and remote validators; `extra.localSource` points at the cached mirror the decoders read, and is dropped whenever those derivatives are invalidated. YouTube links are not media assets.

### MediaReference

Viewing-only provider links live in top-level `references[]` and cannot satisfy a clip's `mediaId`:

```json
{ "id": "…", "provider": "youtube", "url": "https://youtu.be/…",
  "externalId": "M7lc1UVf-VE", "in": "12/1", "out": "20/1" }
```

### Track

| Field | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `kind` | enum | `video` \| `audio` |
| `name` | string | default `"V1"`, `"A1"`… auto-numbered |
| `index` | int | compositing/mix order within kind |
| `mute`, `solo`, `lock`, `hidden` | bool | `hidden` video-only |
| `height` | int | timeline row height px |
| `gain` | float | mixer fader, linear (default `1.0`) — AUD-10 |
| `pan` | float | mixer balance, `-1..+1` (default `0.0`) — AUD-10 |

### Clip

```json
{
  "id": "…", "trackId": "…", "mediaId": "…",
  "label": "interview-take3.mp4",
  "start": "1200/1",            // sequence time
  "duration": "450/3",          // sequence time
  "sourceIn": "3000/1001",      // source time (media fps domain)
  "speed": { "num": 1, "den": 1 },
  "reverse": false,
  "volume": 1.0,                // linear gain; -inf encoded as null
  "pan": 0.0,                   // -1..+1
  "mute": false,
  "fadeIn":  { "duration": "1/2", "curve": "linear" },
  "fadeOut": { "duration": "1/2", "curve": "exponential" },
  "linkedGroup": "…",           // optional: links A/V clips split from one clip
  "effects": [ /* EffectInstance, ordered */ ],
  "transform": { /* ClipTransform — FX-9; params encoded as in EffectInstance */ },
  "text": { /* TextContent — text clips only */ },
  "extra": { /* forward-safe bag: clipAnim (TXT-10), trackPin (TRK-17), … */ }
}
```

Rules:
- `sourceIn + duration × speed ≤ media.duration` enforced for AV segments with media; validation on every mutation.
- Images/text: no `sourceIn`; duration unbounded.
- `speed`: rational ≥ 1/4 and ≤ 4 in v1 (constant only). Audio pitch handling per `03-features/audio.md`.
- `linkedGroup`: when audio is detached from a video clip, both clips share a group id; moving either moves both unless Alt-dragged apart (UX in `03-features/timeline.md`).

### EffectInstance

```json
{
  "id": "…",
  "type": "gaussianBlur",
  "enabled": true,
  "params": {
    "radius": {
      "static": 8.0,
      "keyframes": [
        { "t": "0/1",     "v": 0.0,  "interp": "easeInOut" },
        { "t": "900/300", "v": 14.0, "interp": "linear" }
      ]
    }
  }
}
```

- Keyframe times `t` are **clip-local** (relative to clip start), rational seconds.
- If `keyframes` is non-empty it wins over `static`. Value type per param declared in the effect registry (float, color `{r,g,b,a}`, point `{x,y}`, enum).
- Interpolation enums v1: `linear`, `easeIn`, `easeOut`, `easeInOut`, `hold`. Bezier custom curves reserved for v1.5 (`interp: "bezier"` + handle fields).

### Transition

```json
{
  "id": "…",
  "aClipId": "…", "bClipId": "…",
  "type": "crossDissolve",
  "duration": "1/2",
  "alignment": "center",
  "params": {}
}
```

- Clips referenced must be adjacent-or-overlapping on the **same track**; placement semantics (handle consumption) defined in `03-features/transitions.md`. The overlap region is computed, not stored: `overlap = min(a.end, b.end) − max(a.start, b.start)` and must equal `duration` (validated).
- Types v1: `crossDissolve`, `dipToBlack`, `dipToWhite`, `slideLeft/Right/Up/Down`, `pushLeft/Right/Up/Down`, `zoomIn`, `zoomOut`.

### Marker

`{ "id", "time": "n/d", "name": string?, "color": enum }` — sequence-level.

### Tracker

A solved motion path for a user-drawn region (`03-features/tracking.md`, **TRK-13**).

```json
{
  "id": "…",
  "mediaId": "…",                 // asset the region was solved against
  "sourceClipId": "…",            // clip the region was drawn on
  "startTime": "0/1",             // clip-local, rational
  "endTime": "300/30",
  "searchQuad": [x0,y0, x1,y1, x2,y2, x3,y3],   // source px, TL/TR/BR/BL
  "algorithm": "lk-homography",
  "algorithmVersion": 1,
  "analysisWidth": 720,
  "fps": "30/1",                  // sample rate of `path`
  "path": [ /* 8 numbers per sample: the quad, source px, TL/TR/BR/BL */ ],
  "confidence": [ /* one 0..1 per sample */ ]
}
```

- The path is stored **packed and flat**, not as `EffectInstance`-style keyframe objects. It is
  dense derived data, so per-sample objects would multiply its size several times over for no
  gain — samples are addressed by index from `startTime` at `fps`, never searched.
- Values are rounded to three decimals, and the path is **uniformly decimated** at solve time —
  `fps` records the reduced rate — so a locked-off shot stores a handful of samples rather than
  one per frame (**TRK-14**). Decimation is uniform, and only by divisors of the span, because
  samples are addressed by index: an unevenly thinned path would put everything after a wider
  gap at the wrong time.
- Coordinates are **source pixels**, so a tracker survives a change of sequence resolution and
  is unaffected by the tracked clip's own transform.
- Unlike thumbnails, peaks, transcripts and proxies (§7), a tracker is **not** a deletable
  cache artifact: it combines user-authored input (the drawn region, any corrections) with an
  expensive solve, so it lives in the document and travels with the project.

### ClipTransform

Encoded exactly like `EffectInstance.params` (§5), one param per key: `x`, `y`, `scale`,
`rotation`, `anchor` (point), `opacity`, plus non-animatable `flipH`/`flipV`/`framing`
(`03-features/effects.md` **FX-9**).

- **`corners`** — optional, a `[x0,y0, x1,y1, x2,y2, x3,y3]` quad in **sequence** pixels
  (**TRK-20**). When present it supersedes `x`/`y`/`scale`/`rotation`/`anchor`, because a
  perspective quad cannot be expressed by a single uniform scale and a roll. Animatable like
  any other param; the shared evaluator interpolates it component-wise.

## 6. Text content (summary)

Text clips carry `text` (string, `\n` allowed), style block (font family/postscript name, size, weight, color, stroke, shadow, background box, alignment, letter spacing, line height), and no animation of its own — a text clip animates through the same
`extra.clipAnim` spec as every other visual clip (`03-features/text-keyframes.md`
§ TXT-10). The legacy `text.animation` preset id is read once at load, converted
to that spec, and cleared. Full definition in `03-features/text-keyframes.md`; storage follows the same param/keyframe encoding as effects (animatable: position, scale, rotation, opacity).

## 7. Media management

- **Hashing:** SHA-256 of full file contents, computed in background at import (quick identity `size + mtime(100ns)` used until full hash lands; hash upgrade is silent).
- **Cache keys:** all derived caches (thumbnails, peaks, proxies, decoded tiers, and the `source` mirror of a URL asset) keyed by `(sha256, variant)` under OS cache dir — macOS `~/Library/Caches/CrazyCut/`, Windows `%LOCALAPPDATA%\CrazyCut\Cache`. Caches are safe to delete anytime.
- **Relink:** on open, resolve each asset: (1) path exists & hash matches → ok; (2) scan project folder / last-known parent folder for file with matching hash → relink silently; (3) fuzzy match by name+size → propose in *Missing media* dialog; (4) else offline state.
- **Path strategy:** store absolute path + record original volume name; relative-path mode (project folder–relative) if asset resides inside the project folder → portable projects.

## 8. Files on disk

| Path | Content |
|---|---|
| `<user>/Documents/CrazyCut/<Project>.crazycut` | project JSON (default location, user-changeable) |
| `<project>.crazycut.autosave` | atomic autosave copy (temp write + rename) |
| `<project dir>/backups/<name>-<timestamp>.crazycut` | backup ring (default: every 5 min while dirty, keep 20) |
| cache dir | thumbnails, peaks, proxies, decode caches, URL source mirrors |

Autosave cadence: 2 s debounce after each committed change, plus hard save every 30 s during active editing. Writes are atomic (temp + fsync + rename). On open, if autosave is newer than the main file and differs, show recovery chooser (main / autosave / backups list).

## 9. Versioning & migration

- `schema` string `crazycut/project@<major>`; loaders accept same-major versions; unknown minor fields preserved verbatim round-trip.
- Migrations are pure functions `doc@N → doc@N+1` registered in a table with tests; migration runs on a copy first, original untouched until save.
- Opening a newer-major file: blocked with clear message ("This project was created in a newer version of CrazyCut").

## 10. Invariants (validated on every mutation & load)

1. Clip ranges valid vs media (respecting speed); durations > 0.
2. No two clips overlap on the same **audio** track; overlaps on video tracks exist **only** inside transition spans.
3. Every `trackId`/`mediaId`/clip reference resolves; transitions reference clips sharing a track.
4. Rational times normalized; keyframe times within `[0, clip.duration]` and strictly increasing.
5. Track indices unique per kind; exactly ≥ 1 track of each kind may exist but zero-clip tracks are prunable.
6. Every tracker's `mediaId`/`sourceClipId` resolves; `searchQuad` has exactly 8 numbers;
   `path` length is a non-zero multiple of 8; `confidence` length is `len(path)/8`; the range
   lies within the source clip's duration. A clip's `extra.trackPin.trackerId` resolves.

Violations never crash the app: loader quarantines invalid entities into a report shown once ("3 items repaired — details").

## 11. Example minimal project

```json
{
  "schema": "crazycut/project@1",
  "id": "018f-…", "name": "Untitled",
  "createdAt": "2026-08-21T09:00:00Z", "modifiedAt": "2026-08-21T09:05:00Z",
  "appVersion": "0.1.0",
  "settings": { "width": 1080, "height": 1920, "fps": "30/1", "audioSampleRate": 48000, "background": "#000000" },
  "media": [
    { "id": "m1", "hash": "sha256:ab12…", "name": "clip01.mp4", "path": "/Users/steve/Movies/clip01.mp4",
      "type": "video", "duration": "20020/1001", "hasAudio": true,
      "probe": { "width": 2160, "height": 3840, "rotation": 90, "fps": "30000/1001", "vfr": false,
                 "codec": "h264", "hdr": "none", "audio": "stereo" },
      "proxyPath": null, "thumbStatus": "ready" }
  ],
  "tracks": [
    { "id": "t1", "kind": "video", "name": "V1", "index": 0, "mute": false, "solo": false, "lock": false, "hidden": false, "height": 80 },
    { "id": "t2", "kind": "audio", "name": "A1", "index": 0, "mute": false, "solo": false, "lock": false, "hidden": false, "height": 64 }
  ],
  "clips": [
    { "id": "c1", "trackId": "t1", "mediaId": "m1", "label": "clip01.mp4",
      "start": "0/1", "duration": "500/30", "sourceIn": "0/1",
      "speed": { "num": 1, "den": 1 }, "reverse": false,
      "volume": 1.0, "pan": 0.0, "mute": false,
      "fadeIn": { "duration": "1/2", "curve": "linear" }, "fadeOut": { "duration": "0/1", "curve": "linear" },
      "effects": [
        { "id": "e1", "type": "gaussianBlur", "enabled": true,
          "params": { "radius": { "static": 8.0, "keyframes": [] } } }
      ] }
  ],
  "transitions": [],
  "markers": []
}
```

## 12. Template files

Reusable chunks live outside the project, one `.cctemplate` JSON file per
template under `<CrazyCut>/Templates` (`03-features/templates.md`):

```json
{
  "schema": "crazycut/template@1",
  "id": "…", "name": "Section bumper", "category": "Bumpers",
  "createdAt": "…", "width": 1920, "height": 1080, "fps": "30/1",
  "lanes":   [ { "key": "…", "kind": "video", "offset": 0, "name": "V1" } ],
  "clips":   [ /* Clip payloads, `start` relative to the chunk, `trackId` = lane key */ ],
  "transitions": [ /* Transition payloads, clip ids template-local */ ],
  "media":   [ { "id": "…", "hash": "sha256:…", "path": "…", "probe": { } } ],
  "slots":   [ { "id": "…", "kind": "text|media|duration", "name": "Title",
                 "clipId": "…", "default": "Chapter one" } ],
  "edgeIn":  { "enabled": true, "type": "crossDissolve", "duration": "1/2", "easing": "easeInOut" },
  "edgeOut": { "enabled": true, "type": "dipToBlack", "duration": "1/2", "easing": "easeInOut" }
}
```

- Clip and transition payloads use the *project* encoding (§5) verbatim, so
  everything a clip can carry travels with the template and forward-safety
  (§9) applies to them unchanged. Ids inside a template are local: insertion
  remaps every one of them.
- Times are relative to the chunk's first clip; lanes are offsets from the
  template's base lane, so a chunk lands correctly in any track layout.
- Internal transitions keep their stored `aExtend`/`bExtend`, because the
  captured clips already carry the overlap the transition owns.
- Same major-version gate as projects: `crazycut/template@<major>`.

## Changelog

- v0.3 — `trackers[]` and `extra.trackPin` for area tracking (`03-features/tracking.md`); `transform`/`extra` made explicit on Clip.
- v0.2 — §12 template files.
- v0.1 — Initial draft.
