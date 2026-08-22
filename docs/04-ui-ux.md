# CrazyCut — UI/UX Specification

> Status: Draft v0.1 · Owner: @steve · Last updated: 2026-08-21
> Requirements prefix: **UIX** · Feature behavior lives in `03-features/*`; this doc defines the shell, patterns, and feel.

## 1. Design principles

1. **One obvious way.** Every task has a primary path; alternatives are modifiers, not menus.
2. **Progressive disclosure.** Defaults first, depth on demand: presets → sliders → advanced fields. Nothing requires the advanced layer to succeed.
3. **Direct manipulation.** Drag clips, drag fades, drag keyframes; numeric entry is always available as the precise twin of every gesture.
4. **Never lose work.** Autosave, undo everything, destructive actions confirm once and remain undoable where possible.
5. **Speed you can feel.** Optimistic UI for all edits; the interface never waits on the engine to acknowledge a gesture.

## 2. Information architecture / screen map

```
Project Browser (launch)
└─ Editor
   ├─ Toolbar (top): back to projects · undo/redo · tools (select/cut/text) ·
   │                 snap magnet · quality dropdown · export button (primary)
   ├─ Left panel: Media pool (+ import drop zone)     [collapsible]
   ├─ Center: Program monitor + transport controls
   ├─ Right panel: Inspector (contextual tabs)        [collapsible]
   └─ Bottom: Timeline (tracks) + ruler + transport timecode
Overlays: Export dialog · Queue slide-over · Settings · Missing media · Diagnostics
```

- **UIX-1** Panels collapse/expand with remembered state; layout resets via View menu.
- **UIX-2** Minimum window 1280×720; below that panels auto-collapse to icons. Fullscreen preview (F) hides all chrome.

## 3. Panel specifications

### 3.1 Media pool (`03-features/media-import.md`)
Grid/list toggle, search, sort, zoom slider. Persistent "Import" drop zone card at top. Selection supports multi-insert ("+ Insert at playhead" action bar appears when >0 selected).

### 3.2 Program monitor
- Letterboxed canvas, checkerboard only for transparency (never behind video).
- Overlay toggles: safe margins (action/title), grid, rule-of-thirds (v1: safe margins + grid).
- Zoom control: Fit / 25 / 50 / 100%; playback quality dropdown (Auto/Full/Half/Proxy) reflecting engine tiers.
- Transport: |« prev edit, play/pause (space), next edit », loop in-out toggle, timecode (current / total), master meter.
- On-canvas manipulation for selected visual clips (move/scale/rotate/text-edit per TXT-6).

### 3.3 Inspector
Contextual tabs by selection:
| Selection | Tabs |
|---|---|
| Video/image clip | Transform · Color · Effects · Speed · Audio |
| Text clip | Text · Transform · Effects · Timing(animations) |
| Audio clip | Audio · Speed |
| Transition | Transition (type gallery + duration/easing) |
| Multiple | common subset, multi-edit |
| Nothing | Sequence settings summary |

Row anatomy (animatable params): `label — [slider] — [value] — ◆ — ↺`. See KEY-4.

### 3.4 Timeline
Per `03-features/timeline.md`. Visual language: video clips show filmstrip + name plate; audio clips waveform + name; text clips show content snippet on accent tint; offline slates hatched. Track headers sticky-left. Ruler shows timecode + markers; in/out shaded.

### 3.5 Export dialog & queue
Per `03-features/export.md`. Single dialog, preset tiles first, advanced collapsed.

## 4. Interaction patterns

- **Drag & drop everywhere:** files→pool/timeline, effects→clips, transitions→cuts, presets→clips. Drop targets highlight with intent (insert line vs replace glow).
- **Context menus** carry full verb sets; nothing is reachable *only* via context menu.
- **Toasts** (bottom center): non-blocking feedback, one actionable button max, auto-dismiss 4 s, errors persist until dismissed.
- **Empty states** teach: empty timeline shows a 2-step hint (import → drag); empty pool shows import paths.
- **Hover affordances:** trim zones, fade handles, transition diamonds, keyframe lanes appear on hover with cursor changes.
- **Double-click semantics:** clip→open inspector tab relevant to type; text→edit; ruler→nothing; asset→preview.

## 5. Visual design

- **Theme:** dark-first (editor standard). Neutral gray ramp (bg #141518, panels #1D1F23, elevated #24272C), text #E8EAED primary / #9AA0A6 secondary.
- **Accent:** single vivid accent (default coral #FF5A5F, user-swappable) reserved for selection, playhead, primary buttons.
- **Semantic colors:** video tracks blue-gray plates, audio green waveforms, text purple tint, markers yellow default, errors red, warnings amber.
- **Type:** Inter (bundled) UI-wide; sizes 11–13 px dense chrome, 15 px headers. Tabular numerals for all timecode/values.
- **Motion:** 120–180 ms ease-out micro-animations (panels, dialogs); zero animation on timeline edits (instant, optimistic); reduced-motion OS setting respected.
- **Density:** comfortable default; "compact mode" setting reduces paddings ~20% for laptop screens.

## 6. Accessibility & i18n

- **UIX-3** Full keyboard operability of panels/dialogs; visible focus rings (2 px accent); tab order documented per panel.
- **UIX-4** Contrast ≥ 4.5:1 body text, ≥ 3:1 UI components (WCAG AA); verified in CI via theme lint.
- **UIX-5** All strings externalized (ARB files) from day one; RTL-safe layouts (no hard-coded left/right in code); shipped languages v1: English. Timecode formats locale-aware option.
- **UIX-6** UI scale setting 90–130% independent of OS scaling.

## 7. Keyboard shortcuts (v1 defaults)

macOS ⌘ = Windows Ctrl unless noted.

| Action | Shortcut | | Action | Shortcut |
|---|---|---|---|---|
| Play/pause | Space | | Undo / Redo | ⌘Z / ⇧⌘Z |
| Shuttle back/stop/fwd | J K L | | Save copy | ⇧⌘S |
| Step frame | ← / → | | Split at playhead | S |
| Step 1 s | ⇧← / ⇧→ | | Ripple delete | ⇧⌫ |
| Start / end | Home / End | | Delete | ⌫ |
| Set in / out | I / O | | Add marker | M |
| Clear in/out | ⌥X | | Next/prev marker | ⇧← / ⇧→* (when playhead on marker) |
| Zoom in/out timeline | ⌘= / ⌘− | | Zoom to fit | \ |
| New text at playhead | T | | Add transition | ⌘T |
| Import | ⌘I | | Export | ⌘E |
| Copy / Paste | ⌘C / ⌘V | | Paste Settings | ⌥⌘V |
| Duplicate drag | ⌥drag | | Slip / Slide drag | ⌥drag / ⌘drag body |
| Select all | ⌘A | | Deselect | Esc |
| Preview fullscreen | F | | Snap bypass (hold) | ⌘ |

*Marker navigation uses ↑/↓ when ruler focused; table shows primary binding. Full map editable in Settings → Shortcuts (v1: view-only presets, editing v1.5).

## 8. First-run & onboarding

- **UIX-7** First launch: project browser + one-time 3-card welcome (Open sample · New project · Import files). Sample project (~40 MB download, opt-in) demonstrates cut/text/transition/export in a 45 s guided checklist (checklist dismissible, non-modal).
- **UIX-8** Feature discovery: new-capability hints appear once per feature as small dots on the owning control; never modal tours after first run.

## 9. States & errors

- Loading states: skeletons in pool/browser; progress pills for background jobs; never blocking spinners over the timeline.
- Error taxonomy: recoverable (toast + retry), degraded (banner: e.g., CPU fallback active), fatal-project (recovery chooser). All error copy follows: what happened → impact → action.

## Changelog

- v0.1 — Initial draft.
