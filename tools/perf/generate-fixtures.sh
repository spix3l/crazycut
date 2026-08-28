#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${CC_PERF_FIXTURE_DIR:-$root/fixtures/perf}"
duration="${CC_PERF_FIXTURE_SECONDS:-6}"

command -v ffmpeg >/dev/null || {
  echo "ffmpeg is required to generate performance fixtures" >&2
  exit 1
}
command -v ffprobe >/dev/null || {
  echo "ffprobe is required to describe performance fixtures" >&2
  exit 1
}
mkdir -p "$out"

encode_h264() {
  local target="$1"
  local source="$2"
  if [[ -s "$target" ]]; then return; fi
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "$source" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$duration" \
    -shortest -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p \
    -c:a aac -b:a 96k "$target"
}

# Three independent full-resolution sources exercise three decoder contexts,
# rather than decoding one cached file three times under different asset ids.
encode_h264 "$out/1080p60-a.mp4" \
  "testsrc2=size=1920x1080:rate=60:duration=$duration"
encode_h264 "$out/1080p60-b.mp4" \
  "testsrc2=size=1920x1080:rate=60:duration=$duration,hue=h=70"
encode_h264 "$out/1080p60-c.mp4" \
  "testsrc2=size=1920x1080:rate=60:duration=$duration,hue=h=190"
encode_h264 "$out/4k30.mp4" \
  "testsrc2=size=3840x2160:rate=30:duration=$duration"

# A real mixed-cadence stream. -fps_mode vfr preserves the 24/60 fps input
# timestamps instead of normalising them to a constant output cadence.
if [[ ! -s "$out/1080p-vfr.mp4" ]]; then
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=1920x1080:rate=24:duration=3" \
    -f lavfi -i "testsrc2=size=1920x1080:rate=60:duration=3,hue=h=120" \
    -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0[v]" -map "[v]" \
    -fps_mode vfr -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p \
    "$out/1080p-vfr.mp4"
fi

# HEVC is optional because some redistributable FFmpeg builds intentionally do
# not ship an HEVC encoder. Record absence instead of silently substituting AVC.
hevc_encoder=""
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'libx265'; then
  hevc_encoder="libx265"
fi
if [[ -n "$hevc_encoder" && ! -s "$out/4k30-hevc.mp4" ]]; then
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=3840x2160:rate=30:duration=$duration" \
    -c:v "$hevc_encoder" -preset ultrafast -crf 30 -pix_fmt yuv420p \
    "$out/4k30-hevc.mp4"
fi

python3 "$root/tools/perf/perf_report.py" manifest \
  --fixture-dir "$out" --output "$out/manifest.json"
echo "Performance fixtures: $out"
