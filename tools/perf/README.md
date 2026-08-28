# Fixed-runner performance harness

Run this only on idle, fixed hardware with a Release engine build:

```sh
cmake -S engine -B engine/build -DCMAKE_BUILD_TYPE=Release
cmake --build engine/build -j
tools/perf/run.sh
```

The harness generates deterministic, license-safe 1080p60 and 4K30 AVC
sources, a mixed-cadence VFR source, and HEVC when the local FFmpeg build
offers `libx265`. Generated media and reports are not source artifacts.

Set `CC_PERF_ACCELERATION` to the backend under test (`software`,
`videotoolbox`, or `d3d11va`) and `CC_PERF_PROXY=1` only when paths point to
proxies. The report records both values. To fail on a greater-than-10% p95
regression against a report captured on the same machine image:

```sh
CC_PERF_BASELINE=/opt/crazycut-perf/baseline.json tools/perf/run.sh
```

Never compare reports from different hardware, power modes, OS images, build
types, fixture manifests, proxy modes, or acceleration modes. Promote a new
baseline only after reviewing the report and output video.
