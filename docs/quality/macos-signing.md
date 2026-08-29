# macOS signing, notarization, and publishing

`tools/package-macos.sh` produces `dist/CrazyCut.dmg` that is fully
self-contained: the engine dylib, the export worker, and every third-party
library (ffmpeg, whisper/ggml) are embedded in the bundle, so the DMG installs
and runs on a clean machine — no Homebrew, no build tree. The script signs and
notarizes automatically whenever the credentials below exist on the machine.

For distribution to other people, both credentials are required. Without them
the DMG still builds and works locally, but Gatekeeper on macOS 13+ shows
"Apple could not verify…" and the fix requires a right-click dance — or on
recent macOS versions, a trip to System Settings. Don't publish unsigned.

## One-time setup

### 1. Developer ID Application certificate

The keychain may contain *Apple Development* and *Apple Distribution*
certificates; neither can sign a DMG for outside-the-App-Store distribution.
That needs a **Developer ID Application** certificate from the team in
`app/macos/Runner.xcodeproj` (`DEVELOPMENT_TEAM`), which requires a paid
Apple Developer Program membership:

1. Open **Xcode → Settings → Accounts** and select the team.
2. Click **Manage Certificates…**, then **+** → **Developer ID Application**.
3. Verify it landed:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

The packaging script auto-detects this identity; `CC_SIGN_IDENTITY` overrides.

### 2. Notarization credentials

Pick one of the two mechanisms; both are supported by the script.

**Option A — keychain profile (local machines).** Create an app-specific
password at <https://appleid.apple.com> (Sign-In and Security → App-Specific
Passwords), then store the profile once:

```bash
xcrun notarytool store-credentials crazycut-notary \
  --apple-id you@example.com --team-id <TEAMID> --password <app-specific-password>
```

`CC_NOTARY_PROFILE=crazycut-notary` selects it (see below for making this the
default).

**Option B — App Store Connect API key (machines/CI without a stored
profile).** In App Store Connect → Users and Access → Integrations, create a
team key, download the `.p8`, and pass:

```bash
CC_NOTARY_KEY=/path/to/AuthKey_XXXX.p8 \
CC_NOTARY_KEY_ID=XXXX \
CC_NOTARY_ISSUER=yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy \
bash tools/package-macos.sh
```

## Building

```bash
# Picks up the Developer ID identity automatically; notarizes when
# CC_NOTARY_PROFILE (or the API-key triple) is set:
CC_NOTARY_PROFILE=crazycut-notary bash tools/package-macos.sh
```

Optional `CC_APP_VERSION=0.2.0` stamps the build name (the release workflow
sets it from the git tag).

## Verifying before publishing

```bash
bundle=app/build/macos/Build/Products/Release/CrazyCut.app
codesign -dv "$bundle" 2>&1 | grep -E 'Authority|TeamIdentifier'
spctl -a -t exec -vv "$bundle"   # "accepted", "Notarized Developer ID"
xcrun stapler validate dist/CrazyCut.dmg
```

The script's own audit also fails the build if any binary in the bundle still
references Homebrew or the build tree, so a "Done:" line means the bundle is
self-contained. The remaining manual check is one clean-machine pass: copy the
DMG to a Mac without Homebrew/ffmpeg, install, import a clip, play, and
export.

## Publishing

Preferred flow: push a tag and let CI produce the signed DMG.

```bash
git tag v0.3.0 && git push origin v0.3.0
```

The release workflow imports the Developer ID certificate from secrets,
signs, notarizes with the App Store Connect API key, and publishes the DMG on
the GitHub Release for the tag. Required repository secrets
(Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `MACOS_CERT_P12` | base64 of the exported Developer ID Application `.p12` (see below) |
| `MACOS_CERT_PASSWORD` | the password the `.p12` was exported with |
| `NOTARY_API_KEY_ID` | App Store Connect API key id (10 chars) |
| `NOTARY_API_ISSUER` | App Store Connect API issuer id (uuid) |
| `NOTARY_API_KEY_P8` | contents of the downloaded `AuthKey_<id>.p8` |

Missing secrets don't fail the build — the workflow falls back to an unsigned
DMG.

Exporting the `.p12` (once per certificate): Keychain Access → My
Certificates → select *Developer ID Application: …* → File → Export Items →
`.p12` with a strong password, then:

```bash
base64 -i developer-id.p12 | pbcopy   # paste into MACOS_CERT_P12
```

For an App Store Connect API key: App Store Connect → Users and Access →
Integrations → App Store Connect API → Team Keys → generate a key with
**Developer** role (Admin to create), download the `.p8`, and note the key id
and issuer id.

## Publishing from a local build

When you need a release without pushing a tag:

```bash
CC_NOTARY_PROFILE=crazycut-notary bash tools/package-macos.sh
gh release create vX.Y.Z --draft --verify-tag --title "CrazyCut vX.Y.Z" dist/CrazyCut.dmg
```

Review the draft on the GitHub Releases page, then publish it.

## Licensing note

Bundled ffmpeg is a GPL build (x264/x265) — shipping it inside the DMG
triggers the GPL for the combined distribution; see `docs/01-architecture.md`
§14 and the LICENSE pointers in the README.
