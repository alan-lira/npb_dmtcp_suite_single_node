#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0

"""Transactional Linux TCP receive-window tuning for DMTCP restore.

The helper is intentionally file-path based so its transaction logic can be
validated against controlled temporary files without modifying host sysctls.
The caller is responsible for holding a suite-wide lock for the complete
prepare/release interval.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Callable, Iterable


FORMAT_VERSION = 1


def read_value(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise RuntimeError(f"cannot read {path}: {exc}") from exc


def write_value(path: Path, value: str) -> None:
    try:
        with path.open("w", encoding="utf-8") as handle:
            handle.write(value)
            handle.write("\n")
    except OSError as exc:
        raise RuntimeError(f"cannot write {path}: {exc}") from exc


def parse_positive_integer(text: str, description: str) -> int:
    try:
        value = int(text.strip())
    except ValueError as exc:
        raise RuntimeError(f"{description} must be an integer: {text!r}") from exc
    if value <= 0:
        raise RuntimeError(f"{description} must be greater than zero: {value}")
    return value


def parse_tcp_rmem(text: str, description: str) -> tuple[int, int, int]:
    fields = text.split()
    if len(fields) != 3:
        raise RuntimeError(
            f"{description} must contain exactly three integers: minimum default maximum"
        )
    values = tuple(parse_positive_integer(field, description) for field in fields)
    minimum, default, maximum = values
    if not (minimum <= default <= maximum):
        raise RuntimeError(
            f"{description} must satisfy minimum <= default <= maximum: {text!r}"
        )
    return minimum, default, maximum


def format_tcp_rmem(values: Iterable[int]) -> str:
    return " ".join(str(value) for value in values)


def normalize_rmem_max(text: str) -> str:
    """Return the canonical numeric representation of net.core.rmem_max."""

    return str(parse_positive_integer(text, "net.core.rmem_max value"))


def normalize_tcp_rmem(text: str) -> str:
    """Return a canonical space-delimited net.ipv4.tcp_rmem triplet."""

    return format_tcp_rmem(
        parse_tcp_rmem(text, "net.ipv4.tcp_rmem value")
    )


def write_optional(path_text: str | None, value: str) -> None:
    if path_text:
        path = Path(path_text)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value.rstrip("\n") + "\n", encoding="utf-8")


def atomic_write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def verified_write(
    path: Path,
    value: str,
    description: str,
    *,
    normalize: Callable[[str], str] = lambda text: text.strip(),
) -> None:
    write_value(path, value)
    actual = read_value(path)
    if normalize(actual) != normalize(value):
        raise RuntimeError(
            f"{description} verification failed for {path}: wrote {value!r}, read {actual!r}"
        )


def restore_original_values(
    rmem_max_path: Path,
    tcp_rmem_path: Path,
    original_rmem_max: str,
    original_tcp_rmem: str,
) -> list[str]:
    """Restore in an order that never temporarily leaves tcp_rmem above rmem_max."""

    errors: list[str] = []
    try:
        verified_write(
            tcp_rmem_path,
            original_tcp_rmem,
            "net.ipv4.tcp_rmem restoration",
            normalize=normalize_tcp_rmem,
        )
    except RuntimeError as exc:
        errors.append(str(exc))
    try:
        verified_write(
            rmem_max_path,
            original_rmem_max,
            "net.core.rmem_max restoration",
            normalize=normalize_rmem_max,
        )
    except RuntimeError as exc:
        errors.append(str(exc))
    return errors


def prepare(args: argparse.Namespace) -> int:
    rmem_max_path = Path(args.rmem_max_path)
    tcp_rmem_path = Path(args.tcp_rmem_path)
    state_path = Path(args.state)

    original_rmem_max_text = read_value(rmem_max_path)
    original_tcp_rmem_text = read_value(tcp_rmem_path)
    original_rmem_max = parse_positive_integer(
        original_rmem_max_text, "current net.core.rmem_max"
    )
    original_tcp_rmem = parse_tcp_rmem(
        original_tcp_rmem_text, "current net.ipv4.tcp_rmem"
    )

    target_rmem_max = parse_positive_integer(
        args.target_rmem_max, "target net.core.rmem_max"
    )
    target_tcp_rmem = parse_tcp_rmem(
        args.target_tcp_rmem, "target net.ipv4.tcp_rmem"
    )

    # Never lower host settings during the transaction. The validated target is
    # a floor, not a replacement for a host that is already configured higher.
    applied_tcp_rmem = tuple(
        max(current, target)
        for current, target in zip(original_tcp_rmem, target_tcp_rmem)
    )
    if not (applied_tcp_rmem[0] <= applied_tcp_rmem[1] <= applied_tcp_rmem[2]):
        raise RuntimeError(
            "merged net.ipv4.tcp_rmem values are not monotonic: "
            f"{format_tcp_rmem(applied_tcp_rmem)}"
        )
    applied_rmem_max = max(
        original_rmem_max,
        target_rmem_max,
        applied_tcp_rmem[2],
    )

    applied_rmem_max_text = str(applied_rmem_max)
    applied_tcp_rmem_text = format_tcp_rmem(applied_tcp_rmem)

    payload: dict[str, object] = {
        "format_version": FORMAT_VERSION,
        "rmem_max_path": str(rmem_max_path),
        "tcp_rmem_path": str(tcp_rmem_path),
        "original_rmem_max": original_rmem_max_text,
        "original_tcp_rmem": original_tcp_rmem_text,
        "target_rmem_max": str(target_rmem_max),
        "target_tcp_rmem": format_tcp_rmem(target_tcp_rmem),
        "applied_rmem_max": applied_rmem_max_text,
        "applied_tcp_rmem": applied_tcp_rmem_text,
        "prepare_complete": False,
        "release_complete": False,
    }
    atomic_write_json(state_path, payload)

    try:
        # Raise the global ceiling before raising per-TCP defaults.
        verified_write(
            rmem_max_path,
            applied_rmem_max_text,
            "net.core.rmem_max setup",
            normalize=normalize_rmem_max,
        )
        verified_write(
            tcp_rmem_path,
            applied_tcp_rmem_text,
            "net.ipv4.tcp_rmem setup",
            normalize=normalize_tcp_rmem,
        )
    except RuntimeError as prepare_error:
        rollback_errors = restore_original_values(
            rmem_max_path,
            tcp_rmem_path,
            original_rmem_max_text,
            original_tcp_rmem_text,
        )
        payload["prepare_error"] = str(prepare_error)
        payload["rollback_errors"] = rollback_errors
        atomic_write_json(state_path, payload)
        if rollback_errors:
            raise RuntimeError(
                f"{prepare_error}; rollback also failed: {'; '.join(rollback_errors)}"
            ) from prepare_error
        raise

    payload["prepare_complete"] = True
    atomic_write_json(state_path, payload)

    write_optional(args.original_rmem_max_output, original_rmem_max_text)
    write_optional(args.original_tcp_rmem_output, original_tcp_rmem_text)
    write_optional(args.applied_rmem_max_output, applied_rmem_max_text)
    write_optional(args.applied_tcp_rmem_output, applied_tcp_rmem_text)

    print(
        "[restore-tcp-receive-window] Applied restore-scoped TCP receive-window floors: "
        f"net.core.rmem_max={applied_rmem_max_text}; "
        f"net.ipv4.tcp_rmem={applied_tcp_rmem_text}."
    )
    return 0


def release(args: argparse.Namespace) -> int:
    state_path = Path(args.state)
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"cannot read transaction state {state_path}: {exc}") from exc

    if state.get("format_version") != FORMAT_VERSION:
        raise RuntimeError(
            f"unsupported transaction-state format in {state_path}: "
            f"{state.get('format_version')!r}"
        )
    # A parent-process signal can arrive after the original values are recorded
    # but before prepare marks the transaction complete. Restoring from that
    # partial state is safe and closes the interruption window around sysctl
    # writes.
    for required_key in (
        "rmem_max_path",
        "tcp_rmem_path",
        "original_rmem_max",
        "original_tcp_rmem",
    ):
        if required_key not in state:
            raise RuntimeError(
                f"receive-window transaction state lacks {required_key}: {state_path}"
            )

    rmem_max_path = Path(args.rmem_max_path)
    tcp_rmem_path = Path(args.tcp_rmem_path)
    if str(rmem_max_path) != state.get("rmem_max_path"):
        raise RuntimeError("net.core.rmem_max path does not match transaction state")
    if str(tcp_rmem_path) != state.get("tcp_rmem_path"):
        raise RuntimeError("net.ipv4.tcp_rmem path does not match transaction state")

    current_rmem_max = read_value(rmem_max_path)
    current_tcp_rmem = read_value(tcp_rmem_path)
    state["release_observed_rmem_max"] = current_rmem_max
    state["release_observed_tcp_rmem"] = current_tcp_rmem
    state["release_concurrent_change_detected"] = bool(
        normalize_rmem_max(current_rmem_max)
        != normalize_rmem_max(str(state.get("applied_rmem_max")))
        or normalize_tcp_rmem(current_tcp_rmem)
        != normalize_tcp_rmem(str(state.get("applied_tcp_rmem")))
    )

    errors = restore_original_values(
        rmem_max_path,
        tcp_rmem_path,
        str(state["original_rmem_max"]),
        str(state["original_tcp_rmem"]),
    )
    state["release_errors"] = errors
    state["release_complete"] = not errors
    atomic_write_json(state_path, state)
    if errors:
        raise RuntimeError("; ".join(errors))

    write_optional(args.released_rmem_max_output, read_value(rmem_max_path))
    write_optional(args.released_tcp_rmem_output, read_value(tcp_rmem_path))

    if state["release_concurrent_change_detected"]:
        print(
            "[restore-tcp-receive-window] WARNING: sysctl values changed outside this "
            "transaction; restored the exact values captured before restore."
        )
    print(
        "[restore-tcp-receive-window] Restored the exact previous "
        "net.core.rmem_max and net.ipv4.tcp_rmem values."
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--state", required=True)
    prepare_parser.add_argument("--rmem-max-path", required=True)
    prepare_parser.add_argument("--tcp-rmem-path", required=True)
    prepare_parser.add_argument("--target-rmem-max", required=True)
    prepare_parser.add_argument("--target-tcp-rmem", required=True)
    prepare_parser.add_argument("--original-rmem-max-output")
    prepare_parser.add_argument("--original-tcp-rmem-output")
    prepare_parser.add_argument("--applied-rmem-max-output")
    prepare_parser.add_argument("--applied-tcp-rmem-output")
    prepare_parser.set_defaults(function=prepare)

    release_parser = subparsers.add_parser("release")
    release_parser.add_argument("--state", required=True)
    release_parser.add_argument("--rmem-max-path", required=True)
    release_parser.add_argument("--tcp-rmem-path", required=True)
    release_parser.add_argument("--released-rmem-max-output")
    release_parser.add_argument("--released-tcp-rmem-output")
    release_parser.set_defaults(function=release)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return args.function(args)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
