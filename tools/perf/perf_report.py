#!/usr/bin/env python3
"""Validate, enrich, and compare CrazyCut fixed-runner performance reports."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import resource
import subprocess
import sys
import time
from pathlib import Path


def load(path: str) -> dict:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def write(path: str, value: dict) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def ffprobe(path: Path) -> dict:
    result = subprocess.run(
        [
            "ffprobe", "-v", "error", "-show_entries",
            "format=duration,size:stream=index,codec_name,width,height,avg_frame_rate,r_frame_rate",
            "-of", "json", str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def manifest(args: argparse.Namespace) -> int:
    directory = Path(args.fixture_dir)
    files = []
    for path in sorted(directory.glob("*.mp4")):
        files.append({"name": path.name, "probe": ffprobe(path)})
    write(args.output, {"schema": "crazycut-perf-fixtures@1", "files": files})
    return 0


def validate_report(report: dict) -> list[str]:
    errors: list[str] = []
    if report.get("schema") != "crazycut-perf-report@1":
        errors.append("schema must be crazycut-perf-report@1")
    metadata = report.get("metadata")
    if not isinstance(metadata, dict):
        errors.append("metadata must be an object")
    else:
        for key in (
            "output_resolution", "proxy", "acceleration", "build_type",
            "fixture_manifest_sha256",
        ):
            if key not in metadata:
                errors.append(f"metadata.{key} is required")
    scenarios = report.get("scenarios")
    if not isinstance(scenarios, dict) or not scenarios:
        errors.append("scenarios must be a non-empty object")
    else:
        for name, metric in scenarios.items():
            if not isinstance(metric, dict):
                errors.append(f"scenarios.{name} must be an object")
                continue
            for key in ("p50_ms", "p95_ms", "samples"):
                if not isinstance(metric.get(key), (int, float)):
                    errors.append(f"scenarios.{name}.{key} must be numeric")
    return errors


def validate(args: argparse.Namespace) -> int:
    errors = validate_report(load(args.report))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 2
    print(f"valid performance report: {args.report}")
    return 0


def enrich(args: argparse.Namespace) -> int:
    report = load(args.report)
    timing = load(args.timing) if args.timing else {}
    real = float(timing.get("real_seconds", 0))
    user = float(timing.get("user_seconds", 0))
    system = float(timing.get("system_seconds", 0))
    metadata = report.setdefault("metadata", {})
    manifest_path = metadata.get("fixture_manifest")
    if manifest_path and Path(manifest_path).is_file():
        metadata["fixture_manifest_sha256"] = hashlib.sha256(
            Path(manifest_path).read_bytes()
        ).hexdigest()
    report.setdefault("host", {}).update(
        {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "processor": platform.processor() or "unknown",
            "cpu_count": os.cpu_count(),
        }
    )
    report.setdefault("process", {}).update(
        {
            "wall_seconds": real,
            "cpu_user_seconds": user,
            "cpu_system_seconds": system,
            "cpu_percent_of_one_core": (
                ((user + system) / real * 100) if real else None
            ),
        }
    )
    errors = validate_report(report)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 2
    write(args.report, report)
    return 0


def time_command(args: argparse.Namespace) -> int:
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        print("time requires a command after --", file=sys.stderr)
        return 2
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.monotonic()
    result = subprocess.run(command, cwd=args.cwd)
    elapsed = time.monotonic() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    write(
        args.timing,
        {
            "real_seconds": elapsed,
            "user_seconds": after.ru_utime - before.ru_utime,
            "system_seconds": after.ru_stime - before.ru_stime,
        },
    )
    return result.returncode


def compare(args: argparse.Namespace) -> int:
    current = load(args.current)
    baseline = load(args.baseline)
    errors = validate_report(current) + validate_report(baseline)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 2
    identity_keys = (
        "output_resolution", "source_resolution", "proxy", "acceleration",
        "build_type", "fixture_manifest_sha256",
    )
    mismatches = [
        key for key in identity_keys
        if baseline["metadata"].get(key) != current["metadata"].get(key)
    ]
    if mismatches:
        print(
            "reports are not comparable; mismatched metadata: "
            + ", ".join(mismatches),
            file=sys.stderr,
        )
        return 2
    failures = []
    print("scenario                         baseline p95   current p95   change")
    for name, old in baseline["scenarios"].items():
        if name not in current["scenarios"]:
            failures.append(f"missing scenario: {name}")
            continue
        before = float(old["p95_ms"])
        after = float(current["scenarios"][name]["p95_ms"])
        change = ((after / before) - 1) * 100 if before else 0
        print(f"{name:32} {before:10.2f} ms {after:10.2f} ms {change:+7.1f}%")
        # Decimal report values commonly make exactly 10% arrive as
        # 10.000000000000009. The policy is "greater than 10%", so retain a
        # tiny numerical tolerance at the boundary.
        if change > args.max_regression + 1e-9:
            failures.append(f"{name}: {change:.1f}% slower")
    if failures:
        print(
            f"performance regression exceeds {args.max_regression:.1f}%:\n"
            + "\n".join(failures),
            file=sys.stderr,
        )
        return 1
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    p = commands.add_parser("manifest")
    p.add_argument("--fixture-dir", required=True)
    p.add_argument("--output", required=True)
    p.set_defaults(func=manifest)
    p = commands.add_parser("validate")
    p.add_argument("--report", required=True)
    p.set_defaults(func=validate)
    p = commands.add_parser("enrich")
    p.add_argument("--report", required=True)
    p.add_argument("--timing")
    p.set_defaults(func=enrich)
    p = commands.add_parser("time")
    p.add_argument("--timing", required=True)
    p.add_argument("--cwd")
    p.add_argument("command", nargs=argparse.REMAINDER)
    p.set_defaults(func=time_command)
    p = commands.add_parser("compare")
    p.add_argument("--current", required=True)
    p.add_argument("--baseline", required=True)
    p.add_argument("--max-regression", type=float, default=10.0)
    p.set_defaults(func=compare)
    return root


if __name__ == "__main__":
    parsed = parser().parse_args()
    raise SystemExit(parsed.func(parsed))
