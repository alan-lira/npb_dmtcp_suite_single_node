#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0

"""Integration test for marker-based current-format result summarization."""

from __future__ import annotations

import csv
from pathlib import Path
import subprocess
import sys
import tempfile


REPO_ROOT = Path(__file__).resolve().parent.parent
SUMMARIZER = REPO_ROOT / "scripts" / "summarize_results.py"


def write(path: Path, value: object) -> None:
    path.write_text(f"{value}\n", encoding="utf-8")


def create_marked_baseline(root: Path) -> None:
    run = root / "btD_np16_baseline_rep1"
    run.mkdir()
    write(run / "SUCCESS.marker", "status=SUCCESS")
    write(run / "run_status.txt", "SUCCESS")
    write(run / "total_seconds.txt", 100.0)
    write(run / "baseline_reference_seconds.txt", 100.0)


def create_unmarked_baseline(root: Path) -> None:
    run = root / "btD_np16_baseline_rep2"
    run.mkdir()
    write(run / "run_status.txt", "SUCCESS")
    write(run / "total_seconds.txt", 101.0)


def create_old_named_baseline(root: Path) -> None:
    run = root / "btD_np16_baseline_t30_rep3"
    run.mkdir()
    write(run / "SUCCESS.marker", "status=SUCCESS")
    write(run / "total_seconds.txt", 102.0)


def create_marked_cr(root: Path) -> None:
    run = root / "btD_np16_cr_p30_rep1"
    run.mkdir()
    values = {
        "SUCCESS.marker": "status=SUCCESS",
        "run_status.txt": "SUCCESS",
        "total_seconds.txt": 120.0,
        "checkpoint_seconds.txt": 5.0,
        "post_checkpoint_stabilization_seconds.txt": 2.0,
        "pre_restore_cleanup_seconds.txt": 4.0,
        "original_shutdown_seconds.txt": 1.0,
        "pre_restore_endpoint_verification_seconds.txt": 2.0,
        "pre_restore_final_grace_seconds.txt": 1.0,
        "dmtcp_restore_seconds.txt": 3.0,
        "successful_restore_attempt_seconds.txt": 2.5,
        "restore_attempt_count.txt": 2,
        "restore_retry_count.txt": 1,
        "checkpoint_restore_workflow_overhead_seconds.txt": 14.0,
        "baseline_reference_seconds.txt": 100.0,
        "total_dmtcp_related_overhead_seconds.txt": 20.0,
        "total_dmtcp_related_overhead_percent.txt": 20.0,
        "residual_dmtcp_runtime_difference_seconds.txt": 6.0,
        "checkpoint_size_gb.txt": 25.0,
        "checkpoint_size_gib.txt": 23.28,
        "checkpoint_mean_per_rank_gb.txt": 1.5625,
        "checkpoint_mean_per_rank_gib.txt": 1.455,
    }
    for name, value in values.items():
        write(run / name, value)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="npb-summary-test-") as temp:
        root = Path(temp) / "results"
        output = Path(temp) / "summary"
        root.mkdir()
        create_marked_baseline(root)
        create_unmarked_baseline(root)
        create_old_named_baseline(root)
        create_marked_cr(root)

        completed = subprocess.run(
            [
                sys.executable,
                str(SUMMARIZER),
                "--results-root",
                str(root),
                "--output-dir",
                str(output),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if completed.returncode != 0:
            raise AssertionError(
                f"summarizer failed\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
            )

        with (output / "per_run_results.csv").open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))

        names = {row["run_name"] for row in rows}
        expected = {"btD_np16_baseline_rep1", "btD_np16_cr_p30_rep1"}
        if names != expected:
            raise AssertionError(f"unexpected summarized runs: {names}")

        cr_row = next(row for row in rows if row["scenario"] == "cr")
        if cr_row["restore_seconds"] != "3.000000000":
            raise AssertionError("current dmtcp_restore_seconds.txt was not read")
        if cr_row["successful_restore_attempt_seconds"] != "2.500000000":
            raise AssertionError("successful restore-attempt metric was not read")
        if cr_row["restore_attempt_count"] != "2.000000000":
            raise AssertionError("restore attempt count was not read")
        if cr_row["restore_retry_count"] != "1.000000000":
            raise AssertionError("restore retry count was not read")
        if cr_row["checkpoint_restore_workflow_overhead_seconds"] != "14.000000000":
            raise AssertionError("current workflow metric was not read")

    print("[OK] summarizer requires SUCCESS.marker and current directory/artifact names")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
