#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/fixtures/media/long.mp4"
OUT="/tmp/cc-long-out.mp4"
WORKER="$ROOT/engine/build/crazycut_worker"

if [[ ! -x "$WORKER" ]]; then
  echo "FAIL: build the engine first ($WORKER missing)"
  exit 1
fi

if [[ ! -f "$SRC" ]]; then
  echo "Generating 10-minute fixture…"
  mkdir -p "$(dirname "$SRC")"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=640x360:rate=30:duration=600" \
    -f lavfi -i "sine=frequency=440:duration=600" \
    -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p \
    -c:a aac -b:a 96k \
    "$SRC"
fi

cat > /tmp/cc-sync-job.json <<EOF
{
  "input": "$SRC",
  "output": "$OUT",
  "video": {"codec": "h264", "crf": 23, "preset": "veryfast"},
  "audio": {"codec": "aac", "bitrate": 128000},
  "faststart": true
}
EOF

echo "Transcoding via crazycut_worker…"
"$WORKER" --job /tmp/cc-sync-job.json > /tmp/cc-sync-progress.jsonl
tail -1 /tmp/cc-sync-progress.jsonl

src_dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SRC")
out_dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")
out_v=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of csv=p=0 "$OUT")

audio_streams=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT" | wc -l | tr -d ' ')
if [[ "$audio_streams" -gt 0 ]]; then
  out_a=$(ffprobe -v error -select_streams a:0 -show_entries stream=duration -of csv=p=0 "$OUT")
else
  out_a=""
fi

echo "source container : ${src_dur}s"
echo "output container : ${out_dur}s"
echo "output video     : ${out_v}s"
echo "output audio     : ${out_a:-none}s"

fail=0
delta_container=$(python3 -c "print(abs($src_dur - $out_dur))")
python3 -c "import sys; sys.exit(0 if abs($src_dur - $out_dur) <= 0.1 else 1)" || {
  echo "FAIL: container duration drift ${delta_container}s > 0.1s"; fail=1; }

v=${out_v%%,*}
a=${out_a%%,*}
if [[ -n "$a" ]]; then
  python3 -c "import sys; sys.exit(0 if abs($v - $a) <= 0.05 else 1)" || {
    echo "FAIL: A/V stream duration drift $(python3 -c "print(abs($v - $a))")s > 0.05s"; fail=1; }
else
  echo "WARN: no audio stream in output"
fi

if [[ "$fail" == "0" ]]; then
  echo "PASS: A/V sync within tolerance on 10-minute clip"
else
  exit 1
fi
