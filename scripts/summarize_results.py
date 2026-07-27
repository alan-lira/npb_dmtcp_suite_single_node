#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

from __future__ import annotations

import argparse
import csv
import math
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


RUN_NAME_PATTERN = re.compile(
    r"^(?P<benchmark>bt|cg)(?P<npb_class>[A-Za-z])_np(?P<mpi_ranks>\d+)_"
    r"(?:"
    r"(?P<baseline>baseline)"
    r"|"
    r"cr_(?:p(?P<checkpoint_percent>\d+)|t(?P<checkpoint_delay>[0-9p.]+))"
    r")_rep(?P<repetition>\d+)$",
    re.IGNORECASE,
)


PER_RUN_FIELDS = [
    "run_name",
    "run_directory",
    "benchmark",
    "npb_class",
    "mpi_ranks",
    "scenario",
    "checkpoint_mode",
    "checkpoint_percent",
    "checkpoint_delay_seconds",
    "repetition",
    "total_seconds",
    "checkpoint_seconds",
    "post_checkpoint_stabilization_seconds",
    "pre_restore_cleanup_seconds",
    "original_shutdown_seconds",
    "pre_restore_endpoint_verification_seconds",
    "pre_restore_final_grace_seconds",
    "restore_seconds",
    "successful_restore_attempt_seconds",
    "restore_attempt_count",
    "restore_retry_count",
    "checkpoint_restore_workflow_overhead_seconds",
    "baseline_reference_seconds",
    "total_dmtcp_related_overhead_seconds",
    "total_dmtcp_related_overhead_percent",
    "total_dmtcp_related_direction",
    "residual_dmtcp_runtime_difference_seconds",
    "residual_dmtcp_runtime_direction",
    "checkpoint_size_gb",
    "checkpoint_size_gib",
    "checkpoint_mean_per_rank_gb",
    "checkpoint_mean_per_rank_gib",
]


AGGREGATE_ID_FIELDS = [
    "benchmark",
    "npb_class",
    "mpi_ranks",
    "scenario",
    "checkpoint_mode",
    "checkpoint_percent",
    "checkpoint_delay_seconds",
]


AGGREGATE_METRICS = [
    "total_seconds",
    "checkpoint_seconds",
    "pre_restore_cleanup_seconds",
    "restore_seconds",
    "successful_restore_attempt_seconds",
    "restore_attempt_count",
    "restore_retry_count",
    "checkpoint_restore_workflow_overhead_seconds",
    "baseline_reference_seconds",
    "total_dmtcp_related_overhead_seconds",
    "total_dmtcp_related_overhead_percent",
    "residual_dmtcp_runtime_difference_seconds",
    "checkpoint_size_gb",
    "checkpoint_mean_per_rank_gb",
]


AGGREGATE_FIELDS = (
    AGGREGATE_ID_FIELDS
    + ["successful_repetitions"]
    + [
        field
        for metric in AGGREGATE_METRICS
        for field in (f"{metric}_mean", f"{metric}_std")
    ]
    + [
        "total_dmtcp_related_direction",
        "residual_dmtcp_runtime_direction",
    ]
)


def parse_args() -> argparse.Namespace:
    repository_root = Path(__file__).resolve().parent.parent
    default_results_root = repository_root / "output" / "results"

    parser = argparse.ArgumentParser(
        description=(
            "Summarize successful NPB + DMTCP baseline and checkpoint/restart "
            "runs and generate per-run and aggregate CSV files."
        )
    )
    parser.add_argument(
        "--results-root",
        type=Path,
        default=default_results_root,
        help=(
            "Directory containing run folders. Default: "
            f"{default_results_root}"
        ),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help=(
            "Directory for per_run_results.csv and aggregate_results.csv. "
            "Default: the selected results root."
        ),
    )
    return parser.parse_args()


def read_text(run_dir: Path, name: str) -> Optional[str]:
    path = run_dir / name
    if not path.is_file():
        return None
    value = path.read_text(encoding="utf-8", errors="replace").strip()
    return value or None


def read_number(run_dir: Path, names: Sequence[str]) -> Optional[float]:
    for name in names:
        text = read_text(run_dir, name)
        if text is None or text.upper() == "N/A":
            continue
        try:
            value = float(text)
        except ValueError:
            continue
        if math.isfinite(value):
            return value
    return None


def decode_delay(value: Optional[str]) -> Optional[float]:
    if value is None:
        return None
    try:
        return float(value.replace("p", "."))
    except ValueError:
        return None


def signed_direction(value: Optional[float]) -> str:
    if value is None:
        return "N/A"
    epsilon = 0.5e-6
    if value > epsilon:
        return "slower than baseline"
    if value < -epsilon:
        return "faster than baseline"
    return "no measurable difference"


def residual_direction(value: Optional[float]) -> str:
    direction = signed_direction(value)
    if direction == "slower than baseline":
        return "slower than baseline outside checkpoint/restore workflow"
    if direction == "faster than baseline":
        return "faster than baseline outside checkpoint/restore workflow"
    if direction == "no measurable difference":
        return "no measurable difference outside checkpoint/restore workflow"
    return direction


def short_direction(value: object) -> str:
    if not isinstance(value, (int, float)):
        return "N/A"
    direction = signed_direction(float(value))
    if direction == "slower than baseline":
        return "slower"
    if direction == "faster than baseline":
        return "faster"
    return "same"


def sum_available(values: Iterable[Optional[float]]) -> Optional[float]:
    materialized = list(values)
    if any(value is None for value in materialized):
        return None
    return sum(value for value in materialized if value is not None)


def parse_run_directory(run_dir: Path) -> Optional[Dict[str, object]]:
    match = RUN_NAME_PATTERN.fullmatch(run_dir.name)
    if match is None:
        return None

    if not (run_dir / "SUCCESS.marker").is_file():
        return None

    scenario = "baseline" if match.group("baseline") else "cr"
    checkpoint_percent: Optional[int] = None
    checkpoint_delay = None
    checkpoint_mode = "none"

    if scenario == "cr" and match.group("checkpoint_percent") is not None:
        checkpoint_mode = "percent"
        checkpoint_percent = int(match.group("checkpoint_percent"))
    elif scenario == "cr":
        checkpoint_mode = "delay"
        checkpoint_delay = decode_delay(match.group("checkpoint_delay"))

    checkpoint_seconds = read_number(run_dir, ("checkpoint_seconds.txt",))
    stabilization_seconds = read_number(
        run_dir, ("post_checkpoint_stabilization_seconds.txt",)
    )
    shutdown_seconds = read_number(run_dir, ("original_shutdown_seconds.txt",))
    endpoint_verification_seconds = read_number(
        run_dir, ("pre_restore_endpoint_verification_seconds.txt",)
    )
    final_grace_seconds = read_number(
        run_dir, ("pre_restore_final_grace_seconds.txt",)
    )
    pre_restore_cleanup_seconds = read_number(
        run_dir, ("pre_restore_cleanup_seconds.txt",)
    )
    restore_seconds = read_number(run_dir, ("dmtcp_restore_seconds.txt",))
    successful_restore_attempt_seconds = read_number(
        run_dir, ("successful_restore_attempt_seconds.txt",)
    )
    restore_attempt_count = read_number(run_dir, ("restore_attempt_count.txt",))
    restore_retry_count = read_number(run_dir, ("restore_retry_count.txt",))

    workflow_overhead = read_number(
        run_dir, ("checkpoint_restore_workflow_overhead_seconds.txt",)
    )
    if workflow_overhead is None:
        workflow_overhead = sum_available(
            (
                checkpoint_seconds,
                stabilization_seconds,
                pre_restore_cleanup_seconds,
                restore_seconds,
            )
        )

    total_seconds = read_number(run_dir, ("total_seconds.txt",))
    baseline_reference = read_number(run_dir, ("baseline_reference_seconds.txt",))
    total_overhead = read_number(
        run_dir, ("total_dmtcp_related_overhead_seconds.txt",)
    )
    if total_overhead is None and total_seconds is not None and baseline_reference is not None:
        total_overhead = total_seconds - baseline_reference

    total_overhead_percent = read_number(
        run_dir, ("total_dmtcp_related_overhead_percent.txt",)
    )
    if (
        total_overhead_percent is None
        and total_overhead is not None
        and baseline_reference not in (None, 0.0)
    ):
        total_overhead_percent = total_overhead / baseline_reference * 100.0

    residual_difference = read_number(
        run_dir, ("residual_dmtcp_runtime_difference_seconds.txt",)
    )
    if residual_difference is None and total_overhead is not None and workflow_overhead is not None:
        residual_difference = total_overhead - workflow_overhead

    checkpoint_size_gb = read_number(run_dir, ("checkpoint_size_gb.txt",))
    checkpoint_size_gib = read_number(run_dir, ("checkpoint_size_gib.txt",))
    checkpoint_mean_per_rank_gb = read_number(
        run_dir, ("checkpoint_mean_per_rank_gb.txt",)
    )
    checkpoint_mean_per_rank_gib = read_number(
        run_dir, ("checkpoint_mean_per_rank_gib.txt",)
    )

    # Baseline runs are not launched under DMTCP, so checkpoint/restore fields
    # are intentionally reported as N/A.
    if scenario == "baseline":
        checkpoint_seconds = None
        stabilization_seconds = None
        pre_restore_cleanup_seconds = None
        shutdown_seconds = None
        endpoint_verification_seconds = None
        final_grace_seconds = None
        restore_seconds = None
        successful_restore_attempt_seconds = None
        restore_attempt_count = None
        restore_retry_count = None
        workflow_overhead = None
        total_overhead = None
        total_overhead_percent = None
        residual_difference = None
        checkpoint_size_gb = None
        checkpoint_size_gib = None
        checkpoint_mean_per_rank_gb = None
        checkpoint_mean_per_rank_gib = None

    row: Dict[str, object] = {
        "run_name": run_dir.name,
        "run_directory": str(run_dir.resolve()),
        "benchmark": match.group("benchmark").upper(),
        "npb_class": match.group("npb_class").upper(),
        "mpi_ranks": int(match.group("mpi_ranks")),
        "scenario": scenario,
        "checkpoint_mode": checkpoint_mode,
        "checkpoint_percent": checkpoint_percent,
        "checkpoint_delay_seconds": checkpoint_delay,
        "repetition": int(match.group("repetition")),
        "total_seconds": total_seconds,
        "checkpoint_seconds": checkpoint_seconds,
        "post_checkpoint_stabilization_seconds": stabilization_seconds,
        "pre_restore_cleanup_seconds": pre_restore_cleanup_seconds,
        "original_shutdown_seconds": shutdown_seconds,
        "pre_restore_endpoint_verification_seconds": endpoint_verification_seconds,
        "pre_restore_final_grace_seconds": final_grace_seconds,
        "restore_seconds": restore_seconds,
        "successful_restore_attempt_seconds": successful_restore_attempt_seconds,
        "restore_attempt_count": restore_attempt_count,
        "restore_retry_count": restore_retry_count,
        "checkpoint_restore_workflow_overhead_seconds": workflow_overhead,
        "baseline_reference_seconds": baseline_reference,
        "total_dmtcp_related_overhead_seconds": total_overhead,
        "total_dmtcp_related_overhead_percent": total_overhead_percent,
        "total_dmtcp_related_direction": signed_direction(total_overhead),
        "residual_dmtcp_runtime_difference_seconds": residual_difference,
        "residual_dmtcp_runtime_direction": residual_direction(residual_difference),
        "checkpoint_size_gb": checkpoint_size_gb,
        "checkpoint_size_gib": checkpoint_size_gib,
        "checkpoint_mean_per_rank_gb": checkpoint_mean_per_rank_gb,
        "checkpoint_mean_per_rank_gib": checkpoint_mean_per_rank_gib,
    }
    return row


def mean_std(values: Sequence[float]) -> Tuple[Optional[float], Optional[float]]:
    if not values:
        return None, None
    if len(values) == 1:
        return values[0], 0.0
    return statistics.mean(values), statistics.stdev(values)


def aggregate_rows(rows: Sequence[Dict[str, object]]) -> List[Dict[str, object]]:
    groups: Dict[Tuple[object, ...], List[Dict[str, object]]] = defaultdict(list)
    for row in rows:
        key = tuple(row[field] for field in AGGREGATE_ID_FIELDS)
        groups[key].append(row)

    def group_sort_key(item: Tuple[object, ...]) -> Tuple[object, ...]:
        benchmark, npb_class, mpi_ranks, scenario, mode, percent, delay = item
        scenario_order = 0 if scenario == "baseline" else 1
        mode_order = {"none": 0, "percent": 1, "delay": 2}.get(str(mode), 9)
        target = percent if percent is not None else delay if delay is not None else -1
        return (
            str(benchmark),
            str(npb_class),
            int(mpi_ranks),
            scenario_order,
            mode_order,
            float(target),
        )

    aggregate: List[Dict[str, object]] = []
    for key in sorted(groups, key=group_sort_key):
        members = groups[key]
        record: Dict[str, object] = dict(zip(AGGREGATE_ID_FIELDS, key))
        record["successful_repetitions"] = len(members)

        for metric in AGGREGATE_METRICS:
            values = [
                float(row[metric])
                for row in members
                if isinstance(row.get(metric), (int, float))
                and math.isfinite(float(row[metric]))
            ]
            mean_value, std_value = mean_std(values)
            record[f"{metric}_mean"] = mean_value
            record[f"{metric}_std"] = std_value

        record["total_dmtcp_related_direction"] = signed_direction(
            record.get("total_dmtcp_related_overhead_seconds_mean")
        )
        record["residual_dmtcp_runtime_direction"] = residual_direction(
            record.get("residual_dmtcp_runtime_difference_seconds_mean")
        )
        aggregate.append(record)

    return aggregate


def csv_value(value: object) -> object:
    if value is None:
        return "N/A"
    if isinstance(value, float):
        return f"{value:.9f}"
    return value


def write_csv(path: Path, fields: Sequence[str], rows: Sequence[Dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: csv_value(row.get(field)) for field in fields})


def format_value(value: object, digits: int = 2) -> str:
    if not isinstance(value, (int, float)):
        return "N/A"
    return f"{float(value):.{digits}f}"


def target_label(row: Dict[str, object]) -> str:
    if row["scenario"] == "baseline":
        return "baseline"
    if row["checkpoint_mode"] == "percent":
        return f"{row['checkpoint_percent']}%"
    return f"{format_value(row['checkpoint_delay_seconds'])} s"


def print_console_summary(
    per_run: Sequence[Dict[str, object]], aggregate: Sequence[Dict[str, object]]
) -> None:
    identities = sorted(
        {
            (str(row["benchmark"]), str(row["npb_class"]), int(row["mpi_ranks"]))
            for row in per_run
        }
    )

    for benchmark, npb_class, mpi_ranks in identities:
        matching = [
            row
            for row in aggregate
            if row["benchmark"] == benchmark
            and row["npb_class"] == npb_class
            and row["mpi_ranks"] == mpi_ranks
        ]
        baseline = next((row for row in matching if row["scenario"] == "baseline"), None)

        print()
        print(f"{benchmark}.{npb_class} | MPI ranks={mpi_ranks}")
        print("=" * 72)
        if baseline is None:
            print("Baseline: unavailable")
        else:
            repetitions = int(baseline["successful_repetitions"])
            repetition_label = "repetition" if repetitions == 1 else "repetitions"
            print(
                "Baseline: "
                f"{format_value(baseline['total_seconds_mean'])} ± "
                f"{format_value(baseline['total_seconds_std'])} s "
                f"({repetitions} successful {repetition_label})"
            )

        cr_rows = [row for row in matching if row["scenario"] == "cr"]
        if not cr_rows:
            print("No successful checkpoint/restart runs found.")
            continue

        print()
        print(
            "Target | Reps | Total (s) | Checkpoint (s) | Cleanup (s) | "
            "Restore (s) | Attempts | Workflow (s) | Total DMTCP | Residual difference | Size (GB)"
        )
        print("-" * 160)
        for row in cr_rows:
            total_direction = short_direction(
                row.get("total_dmtcp_related_overhead_seconds_mean")
            )
            residual_direction_short = short_direction(
                row.get("residual_dmtcp_runtime_difference_seconds_mean")
            )
            total_summary = (
                f"{format_value(row['total_dmtcp_related_overhead_percent_mean'])}% "
                f"({total_direction})"
            )
            residual_summary = (
                f"{format_value(row['residual_dmtcp_runtime_difference_seconds_mean'])} s "
                f"({residual_direction_short})"
            )
            print(
                f"{target_label(row):>7} | "
                f"{int(row['successful_repetitions']):4d} | "
                f"{format_value(row['total_seconds_mean']):>9} | "
                f"{format_value(row['checkpoint_seconds_mean']):>14} | "
                f"{format_value(row['pre_restore_cleanup_seconds_mean']):>11} | "
                f"{format_value(row['restore_seconds_mean']):>11} | "
                f"{format_value(row['restore_attempt_count_mean'], 1):>8} | "
                f"{format_value(row['checkpoint_restore_workflow_overhead_seconds_mean']):>12} | "
                f"{total_summary:>19} | "
                f"{residual_summary:>24} | "
                f"{format_value(row['checkpoint_size_gb_mean']):>9}"
            )


def main() -> int:
    args = parse_args()
    results_root = args.results_root.expanduser().resolve()
    output_dir = (
        args.output_dir.expanduser().resolve()
        if args.output_dir is not None
        else results_root
    )

    if not results_root.is_dir():
        print(f"ERROR: results directory not found: {results_root}", file=sys.stderr)
        return 1

    per_run: List[Dict[str, object]] = []
    matching_directories = 0
    skipped_unsuccessful = 0

    for run_dir in sorted(results_root.iterdir()):
        if not run_dir.is_dir() or RUN_NAME_PATTERN.fullmatch(run_dir.name) is None:
            continue
        matching_directories += 1
        row = parse_run_directory(run_dir)
        if row is None:
            skipped_unsuccessful += 1
            continue
        per_run.append(row)

    if not per_run:
        print(
            f"ERROR: no successful result folders found under {results_root}",
            file=sys.stderr,
        )
        return 1

    aggregate = aggregate_rows(per_run)
    per_run_path = output_dir / "per_run_results.csv"
    aggregate_path = output_dir / "aggregate_results.csv"
    write_csv(per_run_path, PER_RUN_FIELDS, per_run)
    write_csv(aggregate_path, AGGREGATE_FIELDS, aggregate)

    print_console_summary(per_run, aggregate)
    print()
    print(f"Successful runs summarized: {len(per_run)}")
    if skipped_unsuccessful:
        print(
            "Matching failed or incomplete run directories skipped: "
            f"{skipped_unsuccessful} of {matching_directories}"
        )
    print(f"Per-run CSV: {per_run_path}")
    print(f"Aggregate CSV: {aggregate_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
