# Headless Windows smoke test for the assembled application bundle.
#
# This deliberately tests native contracts which do not require an interactive
# desktop: runtime dependency loading, the engine ABI, project parsing, audio
# device enumeration, decoded playback-frame delivery, and a real worker
# transcode. The Flutter runner itself is compiled with /WX by its CMake build.
# Interactive texture registration and audible output remain physical-machine
# release checks; see docs/quality/windows-validation.md.

param(
  [Parameter(Mandatory = $true)]
  [string]$Bundle,

  [string]$Fixture = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Fixture) {
  $Fixture = Join-Path $repoRoot "fixtures\media\sample.mp4"
}
$Bundle = (Resolve-Path $Bundle).Path
$Fixture = (Resolve-Path $Fixture).Path

$requiredFiles = @(
  "CrazyCut.exe",
  "crazycut.dll",
  "crazycut_worker.exe",
  "flutter_windows.dll",
  "data\flutter_assets\AssetManifest.bin"
)
foreach ($relative in $requiredFiles) {
  $path = Join-Path $Bundle $relative
  if (-not (Test-Path $path -PathType Leaf)) {
    throw "packaged file missing: $relative"
  }
}

# Ensure Windows resolves the FFmpeg DLLs from the assembled bundle, exactly as
# it will on a clean installation rather than from the CI machine's PATH.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CcWin32 {
  [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool SetDllDirectory(string path);
  [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern IntPtr LoadLibrary(string path);
  [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Ansi)]
  public static extern IntPtr GetProcAddress(IntPtr module, string name);
  [DllImport("kernel32", SetLastError = true)]
  public static extern bool FreeLibrary(IntPtr module);
}

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int CcAbiVersion();
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate IntPtr CcEngineCreate();
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void CcEngineDestroy(IntPtr engine);
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int CcProjectSetSnapshot(
  IntPtr engine,
  [MarshalAs(UnmanagedType.LPUTF8Str)] string json,
  int repair,
  out IntPtr report);
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int CcAudioOutputDevices(IntPtr engine, out IntPtr names);
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate IntPtr CcPlaybackCreate(
  [MarshalAs(UnmanagedType.LPUTF8Str)] string path);
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int CcPlaybackStart(IntPtr playback);
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate IntPtr CcPlaybackLockFrame(
  IntPtr playback, out int width, out int height);
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void CcPlaybackUnlockFrame(IntPtr playback);
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void CcPlaybackDestroy(IntPtr playback);
'@

function Get-CcDelegate {
  param(
    [IntPtr]$Module,
    [string]$Name,
    [Type]$DelegateType
  )
  $address = [CcWin32]::GetProcAddress($Module, $Name)
  if ($address -eq [IntPtr]::Zero) {
    throw "engine ABI symbol missing: $Name"
  }
  return [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
    $address, $DelegateType)
}

if (-not [CcWin32]::SetDllDirectory($Bundle)) {
  throw "SetDllDirectory failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}
$module = [CcWin32]::LoadLibrary((Join-Path $Bundle "crazycut.dll"))
if ($module -eq [IntPtr]::Zero) {
  throw "crazycut.dll or one of its packaged dependencies failed to load: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

$engine = [IntPtr]::Zero
$playback = [IntPtr]::Zero
try {
  $abi = Get-CcDelegate $module "cc_abi_version" ([CcAbiVersion])
  if ($abi.Invoke() -ne 3) { throw "unexpected engine ABI version" }

  $createEngine = Get-CcDelegate $module "cc_engine_create" ([CcEngineCreate])
  $destroyEngine = Get-CcDelegate $module "cc_engine_destroy" ([CcEngineDestroy])
  $setProject = Get-CcDelegate $module "cc_project_set_snapshot" ([CcProjectSetSnapshot])
  $audioDevices = Get-CcDelegate $module "cc_audio_output_devices" ([CcAudioOutputDevices])
  $engine = $createEngine.Invoke()
  if ($engine -eq [IntPtr]::Zero) { throw "cc_engine_create returned null" }

  $project = @{
    schema = "crazycut/project@1"
    id = "windows-smoke"
    settings = @{ width = 320; height = 180; fps = "30/1"; audioSampleRate = 48000 }
    media = @()
    tracks = @(@{ id = "v1"; kind = "video"; index = 0 })
    clips = @()
    transitions = @()
    markers = @()
  } | ConvertTo-Json -Depth 8 -Compress
  $report = [IntPtr]::Zero
  if ($setProject.Invoke($engine, $project, 0, [ref]$report) -ne 0) {
    throw "engine rejected the smoke project"
  }
  $deviceNames = [IntPtr]::Zero
  if ($audioDevices.Invoke($engine, [ref]$deviceNames) -ne 0) {
    throw "audio-device enumeration contract failed"
  }

  # The native runner loads these symbols and copies the resulting RGBA frame
  # into Flutter's PixelBufferTexture. Exercising them here catches ABI,
  # decoder, pacing, and packaged-runtime failures on Windows.
  $createPlayback = Get-CcDelegate $module "cc_playback_create" ([CcPlaybackCreate])
  $startPlayback = Get-CcDelegate $module "cc_playback_start" ([CcPlaybackStart])
  $lockFrame = Get-CcDelegate $module "cc_playback_lock_frame" ([CcPlaybackLockFrame])
  $unlockFrame = Get-CcDelegate $module "cc_playback_unlock_frame" ([CcPlaybackUnlockFrame])
  $destroyPlayback = Get-CcDelegate $module "cc_playback_destroy" ([CcPlaybackDestroy])
  $playback = $createPlayback.Invoke($Fixture)
  if ($playback -eq [IntPtr]::Zero) { throw "playback could not open fixture" }
  if ($startPlayback.Invoke($playback) -ne 0) { throw "playback could not start" }

  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  $frameDelivered = $false
  while ([DateTime]::UtcNow -lt $deadline -and -not $frameDelivered) {
    $width = 0
    $height = 0
    $pixels = $lockFrame.Invoke($playback, [ref]$width, [ref]$height)
    if ($pixels -ne [IntPtr]::Zero) {
      try {
        $frameDelivered = $width -gt 0 -and $height -gt 0
      } finally {
        $unlockFrame.Invoke($playback)
      }
    }
    if (-not $frameDelivered) { Start-Sleep -Milliseconds 50 }
  }
  if (-not $frameDelivered) { throw "playback did not deliver a decoded RGBA frame" }

  $destroyPlayback.Invoke($playback)
  $playback = [IntPtr]::Zero
  $destroyEngine.Invoke($engine)
  $engine = [IntPtr]::Zero
} finally {
  if ($playback -ne [IntPtr]::Zero) {
    $destroy = Get-CcDelegate $module "cc_playback_destroy" ([CcPlaybackDestroy])
    $destroy.Invoke($playback)
  }
  if ($engine -ne [IntPtr]::Zero) {
    $destroy = Get-CcDelegate $module "cc_engine_destroy" ([CcEngineDestroy])
    $destroy.Invoke($engine)
  }
  [CcWin32]::FreeLibrary($module) | Out-Null
}

$smokeDir = Join-Path ([IO.Path]::GetTempPath()) ("crazycut-windows-smoke-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $smokeDir | Out-Null
try {
  $output = Join-Path $smokeDir "worker-output.mp4"
  $jobPath = Join-Path $smokeDir "worker-job.json"
  @{
    input = $Fixture
    output = $output
    video = @{ codec = "h264"; crf = 30; preset = "ultrafast"; maxWidth = 320; maxHeight = 180 }
    audio = @{ codec = "aac"; bitrate = 64000 }
    faststart = $true
  } | ConvertTo-Json -Depth 5 | Set-Content -Path $jobPath -Encoding utf8NoBOM

  $worker = Join-Path $Bundle "crazycut_worker.exe"
  $workerLog = & $worker --job $jobPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "worker export failed:`n$($workerLog -join [Environment]::NewLine)"
  }
  if (-not (Test-Path $output -PathType Leaf) -or (Get-Item $output).Length -lt 1000) {
    throw "worker did not produce a valid-sized output"
  }
  $done = $workerLog | Where-Object { $_ -match '"type"\s*:\s*"done"' }
  if (-not $done) { throw "worker did not report completion" }

  $probe = Get-Command ffprobe.exe -ErrorAction Stop
  $duration = & $probe.Source -v error -show_entries format=duration -of default=nw=1:nk=1 $output
  if ($LASTEXITCODE -ne 0 -or [double]$duration -le 0) {
    throw "ffprobe rejected worker output"
  }
} finally {
  Remove-Item $smokeDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Windows bundle smoke passed: project, audio API, playback frame, worker export"
