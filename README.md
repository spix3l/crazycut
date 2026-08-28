# CrazyCut

A native desktop video editor for solo creators. Simple like Canva, capable like an NLE.

- **Stack:** Flutter (UI) + C++17 engine via FFI + ffmpeg libraries
- **Platforms:** macOS 13+, Windows 10/11 x64
- **License:** MIT (see [LICENSE](LICENSE)); bundled ffmpeg is GPL-built — see `docs/01-architecture.md` §14

## Documentation

Everything lives in [`docs/`](docs/README.md) — start with the [index](docs/README.md).

## Repository layout

```
docs/       spec suite (product, architecture, data model, features, UI/UX, roadmap)
engine/     C++17 core: media probing, decoding, compositing, export worker
app/        Flutter desktop application
tools/      build scripts, ffmpeg build helpers
fixtures/   generated test media + golden references
```

## Development setup (macOS)

```bash
brew install cmake ffmpeg
flutter --version   # 3.24+ stable required

# Build engine + run tests.
# Use RelWithDebInfo, not Debug: the compositor is a per-pixel CPU pipeline and
# an unoptimized build renders preview frames roughly ten times slower, which
# is the difference between realtime playback and a slideshow.
cmake -S engine -B engine/build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build engine/build -j
ctest --test-dir engine/build --output-on-failure

# Regenerate Dart FFI bindings after editing engine/bindings/crazycut.h
bash tools/generate-bindings.sh

# Generate a local test clip (git-ignored)
bash tools/make-fixture.sh

# Package a distributable macOS app + DMG (unsigned unless CC_SIGN_IDENTITY is set)
bash tools/package-macos.sh

# Run the app (auto-discovers engine at ../engine/build)
flutter run
# or with explicit paths:
flutter run --dart-define=CRAZYCUT_ENGINE_LIB=/absolute/path/to/libcrazycut.dylib \
            --dart-define=CRAZYCUT_WORKER_BIN=/absolute/path/to/crazycut_worker

# A/V sync verification on a 10-minute clip (~1 min)
bash tools/check-sync.sh
```

## Windows native playback

The engine, the FFI bindings, and the Dart platform-selection code
(`app/lib/engine/`) are all cross-platform, but native video preview goes
through a platform channel (`dev.crazycut/playback`) backed by
platform-specific code that decodes frames into a Flutter texture:
`app/macos/Runner/NativePlaybackTexture.swift` on macOS and
`app/windows/runner/native_playback_texture.{h,cpp}` on Windows, wired up in
`app/windows/runner/flutter_window.cpp` alongside a Windows port of the
export-quit-guard/sleep-prevention `dev.crazycut/system` channel
(`AppDelegate.swift`'s counterpart).

**The Windows runner code has never been built or run on an actual Windows
machine** — this project has no Windows hardware or VM available in
development. It was written to mirror the macOS implementation's contract
(same method channel, same double-buffered RGBA hand-off pattern) and
compiles against the Flutter Windows embedder headers by inspection, but the
first real build should be treated as a review, not a formality. Before
trusting a release build, at minimum verify:

- `flutter build windows` succeeds and the CMake target picks up
  `native_playback_texture.cpp` (`app/windows/runner/CMakeLists.txt`).
- Opening a clip actually shows frames in the preview (not just that `open`
  returns a texture id) — the `PixelBufferTexture` double-buffer swap is the
  part most likely to have a subtle bug under real frame-rate load.
- The quit-with-exports-running dialog (close the window mid-export) and the
  display-sleep prevention during export actually behave as expected.

CI builds and packages the Windows app on every tag (see below), which at
least proves it compiles and links, but that's not the same as it working.

## Release process

Pushing a tag matching `v*` (e.g. `v0.3.0`) runs
[`.github/workflows/release.yml`](.github/workflows/release.yml), which:

1. Builds the engine and packages the macOS app via `tools/package-macos.sh`
   (signs/notarizes only if `CC_SIGN_IDENTITY`/`CC_NOTARY_PROFILE` secrets are
   set) into a DMG.
2. Builds the engine and packages the Windows app via
   `tools/package-windows.ps1` — see the caveat above — into a zip.
3. Publishes both as assets on a GitHub Release for the tag, with
   auto-generated release notes.

To cut a release:

```bash
git tag v0.3.0
git push origin v0.3.0
```

## Status

Pre-beta. The multi-track editing, effects, audio, export, templates, and AI
foundations are implemented; creator captions, GPU/hardware-decode performance,
release packaging, and beta hardening remain in progress. See the
[capability matrix](docs/07-capability-matrix.md) and
[implementation plan](docs/06-implementation-plan.md).
