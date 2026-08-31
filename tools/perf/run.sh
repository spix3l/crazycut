#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
report="${CC_PERF_REPORT:-$root/build/perf/report.json}"
timing="${report%.json}.timing.json"
fixture_dir="${CC_PERF_FIXTURE_DIR:-$root/fixtures/perf}"
mkdir -p "$(dirname "$report")"

"$root/tools/perf/generate-fixtures.sh"

if [[ ! -f "$root/engine/build/libcrazycut.dylib" && \
      ! -f "$root/engine/build/libcrazycut.so" && \
      ! -f "$root/engine/build/Release/crazycut.dll" ]]; then
  echo "Build the Release engine before running the fixed-hardware benchmark." >&2
  exit 1
fi

# Child-process CPU accounting is deliberately recorded separately from
# scenario wall latency. Fixed runners can identify contention without
# contaminating p95, and user+system cover Flutter plus its test subprocesses.
CC_PERF_RUN=1 \
CC_PERF_FIXTURE_DIR="$fixture_dir" \
CC_PERF_REPORT="$report" \
python3 "$root/tools/perf/perf_report.py" time \
  --timing "$timing" --cwd "$root/app" -- \
  flutter test performance_test/editor/representative_performance_test.dart --reporter expanded
python3 "$root/tools/perf/perf_report.py" enrich \
  --report "$report" --timing "$timing"

if [[ -n "${CC_PERF_BASELINE:-}" ]]; then
  python3 "$root/tools/perf/perf_report.py" compare \
    --baseline "$CC_PERF_BASELINE" --current "$report" --max-regression 10
fi
echo "Performance report: $report"
