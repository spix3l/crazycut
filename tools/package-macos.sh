#!/usr/bin/env bash
# Builds a distributable macOS app: release engine + release Flutter app, with
# the engine library and export worker copied inside the bundle so the app
# works away from the build tree. Produces a DMG in dist/.
#
# Signing and notarization are opt-in through the environment, because they
# need credentials this repository does not carry:
#
#   CC_SIGN_IDENTITY   "Developer ID Application: … (TEAMID)"
#   CC_NOTARY_PROFILE  notarytool keychain profile name
#
# Without them you still get a working, unsigned DMG for local testing; macOS
# will warn on first open (right-click → Open).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
app_dir="$repo_root/app"
engine_build="$repo_root/engine/build-release"
dist="$repo_root/dist"

echo "==> Building engine (Release)"
cmake -S "$repo_root/engine" -B "$engine_build" \
  -DCMAKE_BUILD_TYPE=Release -DCC_BUILD_TESTS=OFF >/dev/null
cmake --build "$engine_build" -j"$(sysctl -n hw.ncpu)"

echo "==> Building app (release)"
cd "$app_dir"
flutter build macos --release

bundle="$app_dir/build/macos/Build/Products/Release/crazycut_app.app"
[[ -d "$bundle" ]] || { echo "error: app bundle not found at $bundle" >&2; exit 1; }

echo "==> Embedding engine artifacts"
frameworks="$bundle/Contents/Frameworks"
resources="$bundle/Contents/Resources"
mkdir -p "$frameworks" "$resources"
cp "$engine_build/libcrazycut.dylib" "$frameworks/"
cp "$engine_build/crazycut_worker" "$resources/"
# The worker links the engine's static core, but it does load ffmpeg dylibs
# from their install paths; a self-contained bundle would relocate those too
# (tracked for the installer milestone).
chmod +x "$resources/crazycut_worker"

if [[ -n "${CC_SIGN_IDENTITY:-}" ]]; then
  echo "==> Signing with $CC_SIGN_IDENTITY"
  codesign --force --options runtime --timestamp \
    --sign "$CC_SIGN_IDENTITY" "$frameworks/libcrazycut.dylib"
  codesign --force --options runtime --timestamp \
    --sign "$CC_SIGN_IDENTITY" "$resources/crazycut_worker"
  codesign --force --options runtime --timestamp --deep \
    --sign "$CC_SIGN_IDENTITY" "$bundle"
  codesign --verify --strict --verbose=2 "$bundle"
else
  echo "==> Skipping code signing (CC_SIGN_IDENTITY not set)"
fi

echo "==> Building DMG"
mkdir -p "$dist"
staging="$(mktemp -d)"
cp -R "$bundle" "$staging/"
ln -s /Applications "$staging/Applications"
dmg="$dist/CrazyCut.dmg"
rm -f "$dmg"
hdiutil create -volname "CrazyCut" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$staging"

if [[ -n "${CC_NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing"
  xcrun notarytool submit "$dmg" --keychain-profile "$CC_NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
else
  echo "==> Skipping notarization (CC_NOTARY_PROFILE not set)"
fi

echo "Done: $dmg"
