# Builds a distributable Windows app: release engine + release Flutter app,
# with the engine DLL, export worker and ffmpeg runtime DLLs copied beside
# the executable so the app works away from the build tree. Produces a zip
# in dist\.
#
# Requires FFMPEG_DIR to point at an ffmpeg shared dev build (the CI release
# job fetches gyan.dev's "release-full-shared" build; see .github/workflows
# for the exact URL). Locally, set $env:FFMPEG_DIR before running.
#
# NOTE: this script (and the native Windows playback runner it packages) has
# only been exercised in CI, never on a physical or virtualized Windows
# machine by a developer on this project — see README.md "Windows native
# playback" before relying on it for a real release.

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $repoRoot "app"
$engineBuild = Join-Path $repoRoot "engine\build-release"
$dist = Join-Path $repoRoot "dist"

if (-not $env:FFMPEG_DIR) {
  throw "FFMPEG_DIR is not set. Point it at an ffmpeg shared dev build (bin\ + lib\ + include\)."
}

Write-Host "==> Building engine (Release)"
cmake -S "$repoRoot\engine" -B "$engineBuild" -DCMAKE_BUILD_TYPE=Release -DCC_BUILD_TESTS=OFF | Out-Null
cmake --build "$engineBuild" --config Release -j
if ($LASTEXITCODE -ne 0) { throw "engine build failed" }

Write-Host "==> Building app (release)"
Push-Location $appDir
try {
  # CC_APP_VERSION, if set (the release workflow sets it from the git tag),
  # stamps the build so About panels and crash reports show the released
  # version rather than pubspec.yaml's placeholder.
  if ($env:CC_APP_VERSION) {
    flutter build windows --release --build-name=$env:CC_APP_VERSION
  } else {
    flutter build windows --release
  }
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed" }
} finally {
  Pop-Location
}

$bundle = Join-Path $appDir "build\windows\x64\runner\Release"
if (-not (Test-Path $bundle)) { throw "app bundle not found at $bundle" }

Write-Host "==> Embedding engine artifacts"
$engineDll = Join-Path $engineBuild "Release\crazycut.dll"
if (-not (Test-Path $engineDll)) { $engineDll = Join-Path $engineBuild "crazycut.dll" }
$workerExe = Join-Path $engineBuild "Release\crazycut_worker.exe"
if (-not (Test-Path $workerExe)) { $workerExe = Join-Path $engineBuild "crazycut_worker.exe" }
Copy-Item $engineDll $bundle -Force
Copy-Item $workerExe $bundle -Force

# The engine links ffmpeg dynamically; ship its DLLs beside the executable
# so the packaged app doesn't depend on ffmpeg being on the target machine.
Get-ChildItem (Join-Path $env:FFMPEG_DIR "bin\*.dll") | ForEach-Object {
  Copy-Item $_.FullName $bundle -Force
}

Write-Host "==> Zipping"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist "CrazyCut-Windows.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $bundle "*") -DestinationPath $zip

Write-Host "Done: $zip"
