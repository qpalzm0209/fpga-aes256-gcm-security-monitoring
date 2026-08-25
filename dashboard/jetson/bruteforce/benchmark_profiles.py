#!/usr/bin/env python3
"""Benchmark the four native weak-key profiles against one captured live record."""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import threading
from datetime import datetime, timezone
from pathlib import Path
import urllib.request


PROFILE_COUNTS = {
    "cpu-multi": 131_072,
    "cuda-low": 524_288,
    "cuda-mid": 1_048_576,
    "cuda-max": 2_097_152,
}


class Metrics:
    FIELDS = ("gpu_util_percent", "cpu_util_percent", "board_power_w",
              "cpu_temp_c", "gpu_temp_c", "memory_used_mb", "memory_total_mb")

    def __init__(self, url: str) -> None:
        self.url = url
        self.rows: list[dict[str, float]] = []
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self.stop.is_set():
            try:
                request = urllib.request.Request(self.url, headers={"Cache-Control": "no-cache"})
                with urllib.request.urlopen(request, timeout=1.0) as response:
                    metrics = json.load(response).get("metrics") or {}
                row = {key: float(metrics[key]) for key in self.FIELDS
                       if metrics.get(key) is not None}
                if row:
                    self.rows.append(row)
            except Exception:
                pass
            self.stop.wait(0.5)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(timeout=2.0)

    def summary(self) -> dict[str, object]:
        keys = sorted({key for row in self.rows for key in row})
        result: dict[str, object] = {"samples": len(self.rows)}
        for key in keys:
            values = [row[key] for row in self.rows if key in row]
            result[key] = {
                "mean": statistics.fmean(values), "min": min(values), "max": max(values)
            }
        return result


def run_profile(binary: Path, record: Path, status: Path, profile: str,
                count: int, metrics_url: str) -> dict[str, object]:
    status.unlink(missing_ok=True)
    with Metrics(metrics_url) as metrics:
        completed = subprocess.run([
            str(binary), "--record", str(record), "--bits", "26",
            "--profile", profile, "--status", str(status),
            "--benchmark-count", str(count),
        ], check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    result = json.loads(completed.stdout.strip().splitlines()[-1])
    if int(result["tested"]) != count or result["found_seed"] is not None:
        raise RuntimeError(f"invalid benchmark completion for {profile}: {result}")
    return {**result, "requested_candidates": count, "system_metrics": metrics.summary()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--record", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--status-dir", type=Path, required=True)
    parser.add_argument("--metrics-url", default="http://100.72.159.6:4173/api/bruteforce/status")
    args = parser.parse_args()
    args.status_dir.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)

    completed = subprocess.run(["/usr/local/cuda-12.6/bin/nvcc", "--version"], check=True, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    profiles = {
        profile: run_profile(args.binary, args.record,
                             args.status_dir / f"benchmark-{profile}.json",
                             profile, count, args.metrics_url)
        for profile, count in PROFILE_COUNTS.items()
    }
    max_rate = float(profiles["cuda-max"]["keys_per_s"])
    estimates = {
        str(bits): {
            "key_space": 2 ** bits,
            "full_scan_s": (2 ** bits) / max_rate,
            "expected_half_scan_s": (2 ** bits) / (2 * max_rate),
        }
        for bits in range(20, 27)
    }
    practical = [bits for bits in range(20, 27)
                 if 10.0 <= estimates[str(bits)]["full_scan_s"] <= 90.0]
    result = {
        "scope": "live_record_full_aes256_gcm_tag_benchmark",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "nvcc_version": completed.stdout.strip(),
        "record_file": str(args.record),
        "profiles": profiles,
        "full_scan_estimates_cuda_max": estimates,
        "recommended_demo_bits": max(practical) if practical else 24,
        "recommendation_rule": "largest N with measured full scan between 10 and 90 seconds",
        "secret_key_included": False,
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
