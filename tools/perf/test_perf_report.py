import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("perf_report.py")


def report(p95: float) -> dict:
    return {
        "schema": "crazycut-perf-report@1",
        "metadata": {
            "output_resolution": "1920x1080",
            "source_resolution": ["1920x1080@60"],
            "proxy": False,
            "acceleration": "software",
            "build_type": "Release",
            "fixture_manifest_sha256": "abc123",
        },
        "scenarios": {
            "three_layers_1080p60": {
                "samples": 30,
                "p50_ms": p95 * 0.8,
                "p95_ms": p95,
            }
        },
    }


class PerfReportTest(unittest.TestCase):
    def run_compare(self, before: float, after: float) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as directory:
            baseline = Path(directory) / "baseline.json"
            current = Path(directory) / "current.json"
            baseline.write_text(json.dumps(report(before)), encoding="utf-8")
            current.write_text(json.dumps(report(after)), encoding="utf-8")
            return subprocess.run(
                [
                    "python3", str(SCRIPT), "compare",
                    "--baseline", str(baseline), "--current", str(current),
                ],
                capture_output=True,
                text=True,
            )

    def test_ten_percent_is_allowed(self) -> None:
        self.assertEqual(self.run_compare(10, 11).returncode, 0)

    def test_more_than_ten_percent_fails(self) -> None:
        result = self.run_compare(10, 11.01)
        self.assertEqual(result.returncode, 1)
        self.assertIn("10.1% slower", result.stderr)

    def test_validator_rejects_missing_run_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "invalid.json"
            value = report(10)
            del value["metadata"]["proxy"]
            path.write_text(json.dumps(value), encoding="utf-8")
            result = subprocess.run(
                ["python3", str(SCRIPT), "validate", "--report", str(path)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("metadata.proxy", result.stderr)

    def test_time_command_records_child_cpu_and_wall_time(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            timing = Path(directory) / "timing.json"
            result = subprocess.run(
                [
                    "python3", str(SCRIPT), "time", "--timing", str(timing),
                    "--", "python3", "-c", "sum(range(100000))",
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            value = json.loads(timing.read_text(encoding="utf-8"))
            self.assertGreaterEqual(value["real_seconds"], 0)
            self.assertGreaterEqual(value["user_seconds"], 0)
            self.assertGreaterEqual(value["system_seconds"], 0)

    def test_enrich_preserves_peak_memory_and_hashes_fixture_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "manifest.json"
            manifest.write_text('{"fixture": 1}\n', encoding="utf-8")
            value = report(10)
            value["metadata"]["fixture_manifest"] = str(manifest)
            del value["metadata"]["fixture_manifest_sha256"]
            value["process"] = {"peak_rss_bytes": 1234}
            report_path = root / "report.json"
            timing_path = root / "timing.json"
            report_path.write_text(json.dumps(value), encoding="utf-8")
            timing_path.write_text(
                json.dumps({
                    "real_seconds": 2,
                    "user_seconds": 1,
                    "system_seconds": 0.5,
                }),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "python3", str(SCRIPT), "enrich", "--report",
                    str(report_path), "--timing", str(timing_path),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            enriched = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(enriched["process"]["peak_rss_bytes"], 1234)
            self.assertEqual(enriched["process"]["cpu_percent_of_one_core"], 75)
            self.assertEqual(
                len(enriched["metadata"]["fixture_manifest_sha256"]), 64
            )


if __name__ == "__main__":
    unittest.main()
