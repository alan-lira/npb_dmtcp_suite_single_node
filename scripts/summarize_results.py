# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

from __future__ import annotations

import argparse
import csv
import re
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Iterable

MODERN_BASELINE = re.compile(
    r"^(?P<benchmark>bt|cg)(?P<class>[A-F])_np(?P<np>\d+)_baseline_rep(?P<rep>\d+)$",
    re.IGNORECASE,
)
LEGACY_BASELINE = re.compile(
    r"^(?P<benchmark>bt|cg)(?P<class>[A-F])_np(?P<np>\d+)_baseline_t(?P<target>[0-9p.]+)_rep(?P<rep>\d+)$",
    re.IGNORECASE,
)
MODERN_CR = re.compile(
    r"^(?P<benchmark>bt|cg)(?P<class>[A-F])_np(?P<np>\d+)_cr_p(?P<point>\d+)_rep(?P<rep>\d+)$",
    re.IGNORECASE,
)
LEGACY_CR = re.compile(
    r"^(?P<benchmark>bt|cg)(?P<class>[A-F])_np(?P<np>\d+)_cr_t(?P<point>[0-9p.]+)_rep(?P<rep>\d+)$",
    re.IGNORECASE,
)


def read_text(run_dir: Path, name: str, default: str = "") -> str:
    path = run_dir / name
    if not path.exists():
        return default
    value = path.read_text().strip()
    return value if value else default


def read_float(run_dir: Path, name: str, default: float = 0.0) -> float:
    value = read_text(run_dir, name, "")
    if not value or value.upper() == "N/A":
        return default
    return float(value)


def read_int(run_dir: Path, name: str, default: int = 0) -> int:
    value = read_text(run_dir, name, "")
    if not value or value.upper() == "N/A":
        return default
    return int(float(value))


def mean_std(values: Iterable[float]) -> tuple[float, float]:
    materialized = list(values)
    if not materialized:
        return 0.0, 0.0
    return (
        statistics.mean(materialized),
        statistics.stdev(materialized) if len(materialized) > 1 else 0.0,
    )


def parse_run_name(name: str) -> dict | None:
    for pattern, scenario, mode in (
        (MODERN_BASELINE, "baseline", "percentage"),
        (LEGACY_BASELINE, "baseline", "seconds"),
        (MODERN_CR, "cr", "percentage"),
        (LEGACY_CR, "cr", "seconds"),
    ):
        match = pattern.fullmatch(name)
        if not match:
            continue
        groups = match.groupdict()
        point_raw = groups.get("point") or groups.get("target") or "0"
        point = float(point_raw.replace("p", "."))
        return {
            "benchmark": groups["benchmark"].lower(),
            "class": groups["class"].upper(),
            "np": int(groups["np"]),
            "scenario": scenario,
            "mode": mode,
            "point": point,
            "rep": int(groups["rep"]),
        }
    return None


def load_rows(results_root: Path) -> tuple[list[dict], list[str]]:
    rows: list[dict] = []
    warnings: list[str] = []

    for run_dir in sorted(results_root.iterdir()):
        if not run_dir.is_dir():
            continue
        parsed = parse_run_name(run_dir.name)
        if parsed is None:
            continue

        status = read_text(run_dir, "run_status.txt")
        if status != "SUCCESS":
            warnings.append(f"Skipping incomplete or failed run: {run_dir}")
            continue
        if not (run_dir / "total_seconds.txt").exists():
            warnings.append(f"Skipping run without total_seconds.txt: {run_dir}")
            continue

        row = dict(parsed)
        row.update(
            {
                "path": run_dir,
                "total_s": read_float(run_dir, "total_seconds.txt"),
                "target_s": read_float(run_dir, "checkpoint_target_seconds.txt"),
                "checkpoint_s": read_float(
                    run_dir,
                    "checkpoint_seconds.txt",
                    read_float(run_dir, "checkpoint_overhead_seconds.txt"),
                ),
                "restore_s": read_float(
                    run_dir,
                    "dmtcp_restore_seconds.txt",
                    read_float(run_dir, "restore_seconds.txt"),
                ),
                "post_restore_s": read_float(
                    run_dir, "post_dmtcp_restore_runtime_seconds.txt"
                ),
                "checkpoint_size_gb": read_float(
                    run_dir,
                    "checkpoint_size_gb.txt",
                    read_float(run_dir, "checkpoint_size_gib.txt") * (1024**3) / 1e9,
                ),
                "checkpoint_mean_rank_gb": read_float(
                    run_dir, "checkpoint_mean_per_rank_gb.txt"
                ),
                "checkpoint_images": read_int(run_dir, "checkpoint_image_count.txt"),
                "clients_before": read_int(
                    run_dir, "dmtcp_clients_before_checkpoint.txt"
                ),
                "clients_restored": read_int(
                    run_dir, "dmtcp_clients_running_after_restore.txt"
                ),
                "restore_complete": read_int(
                    run_dir, "dmtcp_restore_marker_found.txt"
                ),
                "npb_verified": read_int(
                    run_dir, "npb_verification_successful.txt"
                ),
                "dmtcp_signal": read_int(run_dir, "dmtcp_signal.txt"),
                "coordinator_lifecycle": read_text(
                    run_dir, "coordinator_lifecycle.txt", "fresh"
                ),
                "dmtcp_port": read_int(run_dir, "dmtcp_coord_port.txt"),
                "dmtcp_commit": read_text(run_dir, "dmtcp_commit.txt", "unknown"),
                "mpich_version": read_text(run_dir, "mpich_version.txt", "unknown"),
                "mpich_device": read_text(run_dir, "mpich_device.txt", "unknown"),
            }
        )
        if row["checkpoint_mean_rank_gb"] == 0.0 and row["np"] > 0:
            row["checkpoint_mean_rank_gb"] = row["checkpoint_size_gb"] / row["np"]
        rows.append(row)

    return rows, warnings


def attach_baselines(rows: list[dict], warnings: list[str]) -> None:
    baselines: dict[tuple[str, str, int], list[float]] = defaultdict(list)
    for row in rows:
        if row["scenario"] == "baseline":
            baselines[(row["benchmark"], row["class"], row["np"])].append(
                row["total_s"]
            )

    for row in rows:
        values = baselines.get((row["benchmark"], row["class"], row["np"]), [])
        if not values:
            row["baseline_mean_s"] = None
            row["baseline_std_s"] = None
            row["overhead_s"] = None
            row["overhead_percent"] = None
            if row["scenario"] == "cr":
                warnings.append(
                    f"No baseline available for {row['benchmark'].upper()}.{row['class']}, ranks={row['np']}"
                )
            continue

        baseline_mean, baseline_std = mean_std(values)
        row["baseline_mean_s"] = baseline_mean
        row["baseline_std_s"] = baseline_std
        if row["scenario"] == "cr":
            overhead = row["total_s"] - baseline_mean
            row["overhead_s"] = overhead
            row["overhead_percent"] = overhead / baseline_mean * 100 if baseline_mean else 0.0
        else:
            row["overhead_s"] = 0.0
            row["overhead_percent"] = 0.0


def write_per_run_csv(results_root: Path, rows: list[dict]) -> Path:
    output = results_root / "per_run_results.csv"
    fieldnames = [
        "benchmark",
        "class",
        "mpi_ranks",
        "scenario",
        "checkpoint_mode",
        "checkpoint_point",
        "checkpoint_target_seconds",
        "repetition",
        "baseline_mean_seconds",
        "baseline_std_seconds",
        "total_seconds",
        "checkpoint_seconds",
        "restore_seconds",
        "post_restore_runtime_seconds",
        "additional_overhead_seconds",
        "additional_overhead_percent",
        "checkpoint_size_total_gb",
        "checkpoint_size_mean_per_rank_gb",
        "checkpoint_image_count",
        "clients_before_checkpoint",
        "clients_restored",
        "restore_complete",
        "npb_verification_successful",
        "dmtcp_signal",
        "coordinator_lifecycle",
        "dmtcp_port",
        "dmtcp_commit",
        "mpich_version",
        "mpich_device",
        "run_directory",
    ]

    with output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in sorted(
            rows,
            key=lambda item: (
                item["benchmark"],
                item["class"],
                item["np"],
                item["scenario"],
                item["mode"],
                item["point"],
                item["rep"],
            ),
        ):
            writer.writerow(
                {
                    "benchmark": row["benchmark"],
                    "class": row["class"],
                    "mpi_ranks": row["np"],
                    "scenario": row["scenario"],
                    "checkpoint_mode": row["mode"],
                    "checkpoint_point": row["point"],
                    "checkpoint_target_seconds": row["target_s"],
                    "repetition": row["rep"],
                    "baseline_mean_seconds": row["baseline_mean_s"],
                    "baseline_std_seconds": row["baseline_std_s"],
                    "total_seconds": row["total_s"],
                    "checkpoint_seconds": row["checkpoint_s"],
                    "restore_seconds": row["restore_s"],
                    "post_restore_runtime_seconds": row["post_restore_s"],
                    "additional_overhead_seconds": row["overhead_s"],
                    "additional_overhead_percent": row["overhead_percent"],
                    "checkpoint_size_total_gb": row["checkpoint_size_gb"],
                    "checkpoint_size_mean_per_rank_gb": row[
                        "checkpoint_mean_rank_gb"
                    ],
                    "checkpoint_image_count": row["checkpoint_images"],
                    "clients_before_checkpoint": row["clients_before"],
                    "clients_restored": row["clients_restored"],
                    "restore_complete": row["restore_complete"],
                    "npb_verification_successful": row["npb_verified"],
                    "dmtcp_signal": row["dmtcp_signal"],
                    "coordinator_lifecycle": row["coordinator_lifecycle"],
                    "dmtcp_port": row["dmtcp_port"],
                    "dmtcp_commit": row["dmtcp_commit"],
                    "mpich_version": row["mpich_version"],
                    "mpich_device": row["mpich_device"],
                    "run_directory": str(row["path"]),
                }
            )
    return output


def aggregate(rows: list[dict]) -> list[dict]:
    groups: dict[tuple, list[dict]] = defaultdict(list)
    for row in rows:
        if row["scenario"] != "cr" or row["baseline_mean_s"] is None:
            continue
        key = (
            row["benchmark"],
            row["class"],
            row["np"],
            row["mode"],
            row["point"],
        )
        groups[key].append(row)

    output: list[dict] = []
    for key, group in sorted(groups.items()):
        benchmark, npb_class, np, mode, point = key
        values = lambda field: [item[field] for item in group]
        output.append(
            {
                "benchmark": benchmark,
                "class": npb_class,
                "np": np,
                "mode": mode,
                "point": point,
                "repetitions": len(group),
                "baseline": mean_std(values("baseline_mean_s")),
                "target": mean_std(values("target_s")),
                "total": mean_std(values("total_s")),
                "checkpoint": mean_std(values("checkpoint_s")),
                "restore": mean_std(values("restore_s")),
                "post_restore": mean_std(values("post_restore_s")),
                "overhead": mean_std(values("overhead_s")),
                "overhead_percent": mean_std(values("overhead_percent")),
                "size_total": mean_std(values("checkpoint_size_gb")),
                "size_rank": mean_std(values("checkpoint_mean_rank_gb")),
                "all_restored": all(item["restore_complete"] == 1 for item in group),
                "all_verified": all(item["npb_verified"] == 1 for item in group),
                "dmtcp_signal": group[0]["dmtcp_signal"],
                "coordinator_lifecycle": group[0]["coordinator_lifecycle"],
            }
        )
    return output


def write_aggregate_csv(results_root: Path, aggregates: list[dict]) -> Path:
    output = results_root / "aggregate_results.csv"
    fieldnames = [
        "benchmark",
        "class",
        "mpi_ranks",
        "checkpoint_mode",
        "checkpoint_point",
        "repetitions",
        "baseline_mean_seconds",
        "baseline_std_seconds",
        "checkpoint_target_mean_seconds",
        "checkpoint_target_std_seconds",
        "total_mean_seconds",
        "total_std_seconds",
        "checkpoint_mean_seconds",
        "checkpoint_std_seconds",
        "restore_mean_seconds",
        "restore_std_seconds",
        "post_restore_runtime_mean_seconds",
        "post_restore_runtime_std_seconds",
        "additional_overhead_mean_seconds",
        "additional_overhead_std_seconds",
        "additional_overhead_percent_mean",
        "additional_overhead_percent_std",
        "checkpoint_size_total_mean_gb",
        "checkpoint_size_total_std_gb",
        "checkpoint_size_mean_per_rank_gb",
        "checkpoint_size_mean_per_rank_std_gb",
        "all_restores_complete",
        "all_npb_verifications_successful",
        "dmtcp_signal",
        "coordinator_lifecycle",
    ]

    with output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for item in aggregates:
            writer.writerow(
                {
                    "benchmark": item["benchmark"],
                    "class": item["class"],
                    "mpi_ranks": item["np"],
                    "checkpoint_mode": item["mode"],
                    "checkpoint_point": item["point"],
                    "repetitions": item["repetitions"],
                    "baseline_mean_seconds": item["baseline"][0],
                    "baseline_std_seconds": item["baseline"][1],
                    "checkpoint_target_mean_seconds": item["target"][0],
                    "checkpoint_target_std_seconds": item["target"][1],
                    "total_mean_seconds": item["total"][0],
                    "total_std_seconds": item["total"][1],
                    "checkpoint_mean_seconds": item["checkpoint"][0],
                    "checkpoint_std_seconds": item["checkpoint"][1],
                    "restore_mean_seconds": item["restore"][0],
                    "restore_std_seconds": item["restore"][1],
                    "post_restore_runtime_mean_seconds": item["post_restore"][0],
                    "post_restore_runtime_std_seconds": item["post_restore"][1],
                    "additional_overhead_mean_seconds": item["overhead"][0],
                    "additional_overhead_std_seconds": item["overhead"][1],
                    "additional_overhead_percent_mean": item["overhead_percent"][0],
                    "additional_overhead_percent_std": item["overhead_percent"][1],
                    "checkpoint_size_total_mean_gb": item["size_total"][0],
                    "checkpoint_size_total_std_gb": item["size_total"][1],
                    "checkpoint_size_mean_per_rank_gb": item["size_rank"][0],
                    "checkpoint_size_mean_per_rank_std_gb": item["size_rank"][1],
                    "all_restores_complete": item["all_restored"],
                    "all_npb_verifications_successful": item["all_verified"],
                    "dmtcp_signal": item["dmtcp_signal"],
                    "coordinator_lifecycle": item["coordinator_lifecycle"],
                }
            )
    return output


def fmt(pair: tuple[float, float], digits: int = 2) -> str:
    return f"{pair[0]:.{digits}f} ± {pair[1]:.{digits}f}"


def print_summary(rows: list[dict], aggregates: list[dict]) -> None:
    baselines: dict[tuple[str, str, int], list[float]] = defaultdict(list)
    for row in rows:
        if row["scenario"] == "baseline":
            baselines[(row["benchmark"], row["class"], row["np"])].append(row["total_s"])

    grouped: dict[tuple[str, str, int], list[dict]] = defaultdict(list)
    for item in aggregates:
        grouped[(item["benchmark"], item["class"], item["np"])].append(item)

    print("\nNPB/DMTCP checkpoint/restore summary")
    print("====================================")
    for key in sorted(set(baselines) | set(grouped)):
        benchmark, npb_class, np = key
        print(f"\n{benchmark.upper()}.{npb_class}, MPI ranks={np}")
        baseline_values = baselines.get(key, [])
        if baseline_values:
            print(f"Baseline: {fmt(mean_std(baseline_values))} s ({len(baseline_values)} reps)")
        else:
            print("Baseline: unavailable")
        print(
            "Point | Reps | Total (s) | Checkpoint (s) | Restore (s) | "
            "Overhead (s) | Overhead (%) | Size total (GB) | Mean/rank (GB)"
        )
        print("-" * 145)
        for item in grouped.get(key, []):
            point = f"{item['point']:.0f}%" if item["mode"] == "percentage" else f"{item['point']:g}s"
            print(
                f"{point:>5} | {item['repetitions']:>4} | "
                f"{fmt(item['total'])} | {fmt(item['checkpoint'])} | "
                f"{fmt(item['restore'])} | {fmt(item['overhead'])} | "
                f"{fmt(item['overhead_percent'])} | "
                f"{fmt(item['size_total'], 3)} | {fmt(item['size_rank'], 4)}"
            )

    print("\nDefinitions")
    print("-----------")
    print("Total: original DMTCP launch through completion of the restored benchmark.")
    print("Checkpoint: checkpoint request through visibility of all images and restart script.")
    print("Restore: restart-script launch until all expected DMTCP clients are RUNNING.")
    print("Overhead: total CR duration minus the matching baseline mean.")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--results-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "output" / "results",
    )
    args = parser.parse_args()
    root = args.results_root.expanduser().resolve()
    if not root.is_dir():
        parser.error(f"results directory not found: {root}")

    rows, warnings = load_rows(root)
    if not rows:
        parser.error(f"no completed result runs found in {root}")
    attach_baselines(rows, warnings)
    aggregates = aggregate(rows)
    per_run = write_per_run_csv(root, rows)
    aggregate_csv = write_aggregate_csv(root, aggregates)
    print_summary(rows, aggregates)

    if warnings:
        print("\nWarnings")
        print("--------")
        for warning in dict.fromkeys(warnings):
            print(f"- {warning}")

    print("\nCSV outputs")
    print("-----------")
    print(per_run)
    print(aggregate_csv)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
