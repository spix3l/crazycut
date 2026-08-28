# Windows validation

Windows failures are release-blocking. The `engine-windows` job in
`.github/workflows/ci.yml` runs on Windows Server 2022 and performs all of the
following on every pull request and push to `main`:

1. Builds the native engine and export worker with MSVC.
2. Runs the native test suite on Windows.
3. Runs Flutter analysis and the Dart/Flutter test suite on Windows.
4. Builds and assembles the release Windows desktop application.
5. Loads `crazycut.dll` using only DLLs in the assembled application directory.
6. Opens a project snapshot through the packaged engine ABI.
7. Enumerates audio outputs through the packaged engine ABI. An empty list is
   valid on the headless runner; failure of the API is not.
8. Starts playback of the checked-in media fixture and requires delivery of a
   decoded RGBA frame through the same ABI consumed by the Windows texture
   bridge.
9. Drives the packaged worker through a real H.264/AAC export and verifies the
   resulting file with `ffprobe`.

The resulting application ZIP is uploaded as `CrazyCut-Windows-CI`, allowing a
reviewer to test the exact bits which passed the gate.

## What CI does not prove

GitHub's hosted Windows runner has no representative display/GPU/audio setup.
Compilation and ABI smoke coverage cannot prove Flutter texture presentation,
audible output, device switching, GPU-driver behavior, sleep/wake, or installer
behavior. A tagged public build is therefore not release-qualified until the
following checklist passes on physical Windows 10 and Windows 11 systems.

Record OS build, CPU, GPU/driver, audio device, input media codecs, output
codec, tester, date, and the commit/tag with the result.

- Install or unpack on a clean user account without developer tools or FFmpeg.
- Open an existing `.crazycut` project and relink media when prompted.
- Play, pause, seek repeatedly, and confirm that video updates without a black
  frame, tearing, or stale frames.
- Confirm synchronized audible playback, enumerate/switch output devices, and
  repeat once with no audio device connected.
- Export H.264/AAC with software encoding and play the result in Windows Media
  Player and a Chromium browser.
- On supported hardware, repeat with NVENC, QSV, or AMF and verify automatic
  software fallback after an unavailable encoder is selected.
- Start an export, attempt to close CrazyCut, decline once, then confirm cancel
  and verify that no `.part` or job file remains.
- Sleep/wake during idle editing and after an export; verify preview recovers
  and completed output remains valid.
- Repeat representative playback and export on Intel, NVIDIA, and AMD graphics
  before changing Windows playback, rendering, or encoder support claims.

Attach the completed record to the tagged release. Missing physical Windows
10/11 evidence keeps the release marked experimental even when CI is green.
