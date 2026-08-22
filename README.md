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

# Run the app (auto-discovers engine at ../engine/build)
flutter run
# or with explicit paths:
flutter run --dart-define=CRAZYCUT_ENGINE_LIB=/absolute/path/to/libcrazycut.dylib \
            --dart-define=CRAZYCUT_WORKER_BIN=/absolute/path/to/crazycut_worker

# A/V sync verification on a 10-minute clip (~1 min)
bash tools/check-sync.sh
```

## Status

M0 (walking skeleton) in progress — see `docs/05-roadmap.md`.
