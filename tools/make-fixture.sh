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

# A clip for the area tracker with known ground truth: a richly textured still,
# panned by exactly 2 px per frame. Anything tracked in it must translate by
# -2 px in x per frame and hold its y and its size (docs/03-features/tracking.md).
#
# testsrc2 is useless here — flat colour bars with a flickering checkerboard is
# close to the worst case for feature tracking, and nothing in it has a knowable
# position. The input framerate is pinned because `n` in the crop expression
# counts *input* frames: leaving it to default to 25 while the output is 30 makes
# the real motion 1.667 px per output frame, not 2, and every assertion built on
# it is quietly wrong.
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "mandelbrot=size=1280x720:rate=1" -frames:v 1 "$OUT/track-texture.png"
ffmpeg -y -hide_banner -loglevel error \
  -loop 1 -framerate 30 -i "$OUT/track-texture.png" -t 3 \
  -vf "crop=640:360:x='2*n':y=180,format=yuv420p" \
  -c:v libx264 -preset veryfast -crf 12 -r 30 \
  "$OUT/track-pan.mp4"
rm -f "$OUT/track-texture.png"

echo "wrote $OUT/sample.mp4, $OUT/animated.gif and $OUT/track-pan.mp4"
