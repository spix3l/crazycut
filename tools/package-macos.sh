#!/usr/bin/env bash
# Builds a distributable macOS app: release engine + release Flutter app, with
# the engine library, the export worker, and every third-party dylib (ffmpeg,
# whisper/ggml) copied inside the bundle so the app runs on a clean machine —
# no Homebrew, no build tree. Produces a DMG in dist/.
#
# Signing and notarization are automatic when credentials exist:
#
#   CC_SIGN_IDENTITY    "Developer ID Application: … (TEAMID)"; auto-detected
#                       from the keychain when unset
#   CC_NOTARY_PROFILE   notarytool keychain profile name (see
#                       docs/quality/macos-signing.md)
#   CC_NOTARY_KEY_ID /  App Store Connect API key, an alternative to
#   CC_NOTARY_ISSUER /  CC_NOTARY_PROFILE that works on machines (and CI
#   CC_NOTARY_KEY       runners) with no stored keychain profile
#
# Without signing you still get a working, unsigned DMG for local testing;
# macOS Gatekeeper will block first launch on another machine.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
app_dir="$repo_root/app"
engine_build="$repo_root/engine/build-release"
dist="$repo_root/dist"

log() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

log "Building engine (Release)"
cmake -S "$repo_root/engine" -B "$engine_build" \
  -DCMAKE_BUILD_TYPE=Release -DCC_BUILD_TESTS=OFF >/dev/null
cmake --build "$engine_build" -j"$(sysctl -n hw.ncpu)"

log "Building app (release)"
cd "$app_dir"
# CC_APP_VERSION, if set (the release workflow sets it from the git tag),
# stamps the build so About panels and crash reports show the released
# version rather than pubspec.yaml's placeholder.
if [[ -n "${CC_APP_VERSION:-}" ]]; then
  flutter build macos --release --build-name="$CC_APP_VERSION"
else
  flutter build macos --release
fi

bundle="$app_dir/build/macos/Build/Products/Release/CrazyCut.app"
[[ -d "$bundle" ]] || die "app bundle not found at $bundle"

# ---------------------------------------------------------------------------
# Third-party dylib bundling
#
# The engine links Homebrew ffmpeg by absolute path and whisper/ggml by
# @rpath into the build tree, both of which are wrong for another machine.
# Everything non-system gets copied into Contents/Frameworks and rewritten
# to @rpath/<name>; the engine artifacts get their build-tree rpaths stripped.
# ---------------------------------------------------------------------------

frameworks="$bundle/Contents/Frameworks"
resources="$bundle/Contents/Resources"
mkdir -p "$frameworks" "$resources"

log "Embedding engine artifacts"
cp "$engine_build/libcrazycut.dylib" "$frameworks/"
cp "$engine_build/crazycut_worker" "$resources/"
# The worker is a raw executable, not an app bundle resource copy, so keep it
# executable by hand.
chmod +x "$resources/crazycut_worker"

otool_deps() { otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'; }
otool_rpaths() {
  otool -l "$1" 2>/dev/null \
    | grep -A2 'cmd LC_RPATH' | grep ' path ' | awk '{print $2}'
}

# Classify a dependency reference: prints "system" for OS libraries, "rpath"
# for @-prefixed references, "bundled-path" (echoes the path) for absolute
# paths that point outside the machine (Homebrew, the engine build tree).
classify_dep() {
  local ref="$1"
  case "$ref" in
    @*) echo rpath ;;
    /usr/lib/*|/System/*) echo system ;;
    *) echo "$ref" ;;
  esac
}

# Every dylib we bundle, by the install name other code references it with.
# Membership doubles as the dedupe check (kept bash-3.2 compatible).
declare -a bundled_names=()
bundled_contains() { [[ " ${bundled_names[*]-} " == *" $1 "* ]]; }

# Homebrew prefix detected from the first absolutely-referenced dylib; used
# to resolve @rpath siblings (some Homebrew bottles, e.g. webp → libsharpyuv,
# reference same-formula libs via @rpath instead of absolute paths).
brew_root=""

# Locate the real file (or a symlink resolving to it) behind a name in the
# whisper/ggml build tree. Returns 0 even when nothing matches; callers
# check emptiness.
resolve_build_tree_dylib() {
  local p
  while IFS= read -r p; do
    printf '%s' "$p"
    return 0
  done < <(find "$engine_build/_deps" -name "$1" 2>/dev/null)
  return 0
}

# Same, in the Homebrew prefix (opt links and Cellar real files).
resolve_homebrew_dylib() {
  local root p
  for root in ${brew_root:+"$brew_root"} /opt/homebrew /usr/local; do
    [[ -d "$root" ]] || continue
    while IFS= read -r p; do
      printf '%s' "$p"
      return 0
    done < <(find "$root/opt" "$root/Cellar" -name "$1" 2>/dev/null)
  done
  return 0
}

# Copy a dylib into Frameworks under `name` and normalize it: its install id
# becomes @rpath/name and every non-system dependency becomes @rpath/<dep>.
bundle_dylib() {
  local name="$1" src="$2" dest="$frameworks/$name" dep cls depname
  bundled_contains "$name" && return 0
  bundled_names+=("$name")

  cp -L "$src" "$dest"
  chmod 644 "$dest"
  install_name_tool -id "@rpath/$name" "$dest"

  # CMake bakes build-tree rpaths into the whisper/ggml dylibs; replace them
  # with one that resolves their @rpath references inside Frameworks.
  while IFS= read -r rp; do
    [[ "$rp" == "$engine_build"* ]] && install_name_tool -delete_rpath "$rp" "$dest"
  done < <(otool_rpaths "$dest")
  install_name_tool -add_rpath "@loader_path" "$dest" 2>/dev/null || true

  for dep in $(otool_deps "$dest"); do
    cls="$(classify_dep "$dep")"
    if [[ "$cls" == rpath ]]; then
      # Every @rpath/NAME.dylib reference must resolve inside Frameworks, so
      # pull the target in regardless of whose bottle it came from.
      depname="${dep#@rpath/}"
      [[ "$depname" == *.dylib ]] && track_dylib "$depname"
      continue
    fi
    [[ "$cls" == system ]] && continue
    depname="$(basename "$dep")"
    install_name_tool -change "$dep" "@rpath/$depname" "$dest"
    track_dylib "$depname" "$dep"
  done
}

# Queue a referenced name for bundling: absolute paths are copied as-is;
# bare names are resolved against the whisper/ggml build tree first, then
# the Homebrew prefix.
track_dylib() {
  local name="$1" src="${2:-}"
  bundled_contains "$name" && return 0
  if [[ -n "$src" && -f "$src" ]]; then
    :
  elif [[ "$name" == libwhisper.* || "$name" == libggml* ]]; then
    src="$(resolve_build_tree_dylib "$name")"
    [[ -n "$src" ]] || die "cannot locate $name in the engine build tree"
  else
    src="$(resolve_homebrew_dylib "$name")"
    [[ -n "$src" ]] || die "no source found for required dylib $name"
  fi
  case "$src" in
    /opt/homebrew/*) [[ -z "$brew_root" ]] && brew_root=/opt/homebrew ;;
    /usr/local/*) [[ -z "$brew_root" ]] && brew_root=/usr/local ;;
  esac
  bundle_dylib "$name" "$src"
}

log "Bundling third-party dylibs (ffmpeg, whisper/ggml)"
# Seed from the engine artifacts: absolute Homebrew references and @rpath
# whisper/ggml references alike.
for artifact in "$frameworks/libcrazycut.dylib" "$resources/crazycut_worker"; do
  for dep in $(otool_deps "$artifact"); do
    cls="$(classify_dep "$dep")"
    [[ "$cls" == system || "$cls" == rpath ]] && continue
    track_dylib "$(basename "$dep")" "$dep"
  done
  for dep in $(otool_deps "$artifact"); do
    [[ "$dep" == @rpath/* ]] || continue
    # The first entry is the artifact's own install name, not a dependency.
    [[ "${dep#@rpath/}" == libcrazycut* ]] && continue
    track_dylib "${dep#@rpath/}"
  done
done

# Rewire the engine artifacts onto the bundle: absolute Homebrew references
# become @rpath, and the build-tree rpaths whisper/ggml were linked with are
# replaced by one that finds Frameworks from each artifact's new home.
for artifact in "$frameworks/libcrazycut.dylib" "$resources/crazycut_worker"; do
  for dep in $(otool_deps "$artifact"); do
    cls="$(classify_dep "$dep")"
    [[ "$cls" == system || "$cls" == rpath ]] && continue
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$artifact"
  done
  while IFS= read -r rp; do
    [[ "$rp" == "$engine_build"* ]] && install_name_tool -delete_rpath "$rp" "$artifact"
  done < <(otool_rpaths "$artifact")
done
# libcrazycut.dylib sits in Frameworks; the worker sits in Resources.
install_name_tool -add_rpath "@loader_path" "$frameworks/libcrazycut.dylib" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../Frameworks" "$resources/crazycut_worker" 2>/dev/null || true

# The app binary must find @rpath dylibs in Frameworks too. Xcode's template
# already ships @executable_path/../Frameworks, so this only patches runners
# that lost it.
if ! otool_rpaths "$bundle/Contents/MacOS/CrazyCut" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$bundle/Contents/MacOS/CrazyCut"
  touched_app_binary=1
fi

# ---------------------------------------------------------------------------
# Code signing
#
# Everything install_name_tool touched lost its signature, so each rewritten
# binary is re-signed regardless; without any identity we ad-hoc sign, which
# keeps arm64 dyld happy locally. Distribution signing signs every nested
# artifact leaf-first with the Developer ID identity, then the bundle with
# the release entitlements (re-signing without --entitlements would silently
# drop them, taking the Hardened Runtime exceptions notarization relies on).
# ---------------------------------------------------------------------------

sign_identity="${CC_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
  sign_identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ && $0 !~ /CSSMERR|invalid/ {print $2; exit}')"
fi

sign_one() { # sign_one <path>
  if [[ -n "$sign_identity" ]]; then
    codesign --force --options runtime --timestamp --sign "$sign_identity" "$1"
  else
    codesign --force --sign - "$1"
  fi
}

if [[ -n "$sign_identity" ]]; then
  log "Signing with $sign_identity"
  for name in "${bundled_names[@]}"; do
    sign_one "$frameworks/$name"
  done
  sign_one "$frameworks/libcrazycut.dylib"
  # Nested frameworks ship from the Flutter build signed with the development
  # identity; notarization wants every nested artifact under the same team.
  while IFS= read -r fw; do
    find "$fw" -name '*.dylib' -type f | while IFS= read -r inner; do sign_one "$inner"; done
    sign_one "$fw"
  done < <(find "$frameworks" -name '*.framework' -maxdepth 1 -type d)
  sign_one "$resources/crazycut_worker"
  codesign --force --options runtime --timestamp \
    --entitlements "$app_dir/macos/Runner/Release.entitlements" \
    --sign "$sign_identity" "$bundle"
  codesign --verify --strict --verbose=2 "$bundle"
else
  log "No Developer ID identity found — ad-hoc signing only (unsigned DMG)"
  for name in "${bundled_names[@]}"; do
    codesign --force --sign - "$frameworks/$name"
  done
  codesign --force --sign - "$frameworks/libcrazycut.dylib"
  codesign --force --sign - "$resources/crazycut_worker"
  # The embedded files broke the Xcode-applied resource seal; re-seal so the
  # bundle still verifies.
  codesign --force --options runtime \
    --entitlements "$app_dir/macos/Runner/Release.entitlements" \
    --sign - "$bundle"
fi

# ---------------------------------------------------------------------------
# Self-containment audit: nothing may reference Homebrew or the build tree.
# ---------------------------------------------------------------------------

audit_fail=0
while IFS= read -r f; do
  if otool_deps "$f" | grep -E '^/(opt|usr/local)/' | grep -q .; then
    echo "error: $f still references an unbundled dylib:" >&2
    otool_deps "$f" | grep -E '^/(opt|usr/local)/' >&2
    audit_fail=1
  fi
  # An @rpath/X.dylib reference only resolves if X sits in Frameworks —
  # this is what catches Homebrew bottles' same-formula @rpath siblings.
  while IFS= read -r dep; do
    [[ "$dep" == @rpath/*.dylib ]] || continue
    depname="${dep#@rpath/}"
    [[ "$depname" == libcrazycut* ]] && continue
    if [[ ! -f "$frameworks/$depname" ]]; then
      echo "error: $f references @rpath/$depname, which is not bundled" >&2
      audit_fail=1
    fi
  done < <(otool_deps "$f")
  if otool_rpaths "$f" | grep -q "$engine_build"; then
    echo "error: $f still has a build-tree rpath:" >&2
    otool_rpaths "$f" | grep "$engine_build" >&2
    audit_fail=1
  fi
done < <(find "$frameworks" "$resources" -type f \
  \( -name '*.dylib' -o -name 'crazycut_worker' \))
[[ "$audit_fail" -eq 0 ]] || die "bundle is not self-contained"

# ---------------------------------------------------------------------------
# DMG
# ---------------------------------------------------------------------------

log "Building DMG"
mkdir -p "$dist"
staging="$(mktemp -d)"
cp -R "$bundle" "$staging/"
ln -s /Applications "$staging/Applications"
dmg="$dist/CrazyCut.dmg"
rm -f "$dmg"
hdiutil create -volname "CrazyCut" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$staging"

# ---------------------------------------------------------------------------
# Notarization
# ---------------------------------------------------------------------------

notarize_args=()
if [[ -n "${CC_NOTARY_PROFILE:-}" ]]; then
  notarize_args=(--keychain-profile "$CC_NOTARY_PROFILE")
elif [[ -n "${CC_NOTARY_KEY_ID:-}" && -n "${CC_NOTARY_ISSUER:-}" && -n "${CC_NOTARY_KEY:-}" ]]; then
  # The script changed directory for the Flutter build, so a relative key
  # path from the caller resolves against the repo root, not the CWD.
  notary_key="$CC_NOTARY_KEY"
  [[ "$notary_key" == /* ]] || notary_key="$repo_root/$notary_key"
  notarize_args=(--key "$notary_key" --key-id "$CC_NOTARY_KEY_ID" --issuer "$CC_NOTARY_ISSUER")
fi

if [[ ${#notarize_args[@]} -gt 0 ]]; then
  [[ -n "$sign_identity" ]] || die "notarization needs a Developer ID-signed build"
  log "Notarizing"
  xcrun notarytool submit "$dmg" "${notarize_args[@]}" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
else
  log "Skipping notarization (no CC_NOTARY_PROFILE or CC_NOTARY_KEY_ID/ISSUER/KEY)"
fi

echo "Done: $dmg"
if [[ -z "$sign_identity" ]]; then
  echo "Unsigned build — for distribution, set up Developer ID signing first:"
  echo "  docs/quality/macos-signing.md"
fi
