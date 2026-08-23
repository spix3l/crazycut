#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/fixtures/media"
mkdir -p "$OUT"

ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "testsrc2=size=640x360:rate=30:duration=10" \
  -f lavfi -i "sine=frequency=440:duration=10" \
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p \
  -c:a aac -b:a 128k \
  "$OUT/sample.mp4"

ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "color=c=red:s=16x16:r=1:d=1" \
  -f lavfi -i "color=c=blue:s=16x16:r=1:d=1" \
  -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0" \
  -loop 0 \
  "$OUT/animated.gif"

echo "wrote $OUT/sample.mp4 and $OUT/animated.gif"
