#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

"""Reserve captured TCP listener ports during DMTCP restart.

DMTCP creates a temporary IPv4 restore listener with bind(port=0). Linux may
otherwise assign that temporary listener a port that a restored application
socket must recreate moments later. This helper adds captured original IPv4
TCP LISTEN ports to net.ipv4.ip_local_reserved_ports before restart and restores
the previous setting after the socket-restart phase.

The caller must hold the suite-wide lock for the complete prepare/use/release
transaction. The helper records enough state to restore the exact previous
value when no external writer changed the sysctl in the meantime. If an
external change is detected, release preserves that change while removing only
ports added by this transaction and restoring ports that existed originally.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
from typing import Iterable, Optional, Sequence, Set


class ReservationError(RuntimeError):
    """Expected reservation failure."""


def parse_nonnegative_float(value: str) -> float:
    parsed = float(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("value must be nonnegative")
    return parsed


def parse_port_set(text: str) -> Set[int]:
    ports: Set[int] = set()
    stripped = text.strip()
    if not stripped:
        return ports
    for token in stripped.split(","):
        token = token.strip()
        if not token:
            continue
        if "-" in token:
            first_text, last_text = token.split("-", 1)
            try:
                first = int(first_text)
                last = int(last_text)
            except ValueError as exc:
                raise ReservationError(f"invalid reserved-port range: {token!r}") from exc
            if first > last:
                raise ReservationError(f"descending reserved-port range: {token!r}")
            candidates: Iterable[int] = range(first, last + 1)
        else:
            try:
                candidates = (int(token),)
            except ValueError as exc:
                raise ReservationError(f"invalid reserved port: {token!r}") from exc
        for port in candidates:
            if not 1 <= port <= 65535:
                raise ReservationError(f"reserved port outside 1..65535: {port}")
            ports.add(port)
    return ports


def format_port_set(ports: Iterable[int]) -> str:
    ordered = sorted(set(ports))
    if not ordered:
        return ""
    ranges = []
    start = previous = ordered[0]
    for port in ordered[1:]:
        if port == previous + 1:
            previous = port
            continue
        ranges.append(str(start) if start == previous else f"{start}-{previous}")
        start = previous = port
    ranges.append(str(start) if start == previous else f"{start}-{previous}")
    return ",".join(ranges)


def read_sysctl(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ReservationError(f"cannot read {path}: {exc}") from exc


def write_sysctl(path: Path, value: str) -> None:
    try:
        with path.open("w", encoding="utf-8") as handle:
            handle.write(value)
            handle.write("\n")
    except OSError as exc:
        raise ReservationError(f"cannot write {path}: {exc}") from exc


def captured_ipv4_tcp_listener_ports(capture_state: Path) -> Set[int]:
    try:
        data = json.loads(capture_state.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ReservationError(f"cannot read captured cleanup state {capture_state}: {exc}") from exc
    if data.get("format_version") != 1:
        raise ReservationError(f"unsupported cleanup-state format in {capture_state}")

    ports: Set[int] = set()
    for item in data.get("sockets", []):
        if not isinstance(item, dict):
            continue
        if item.get("protocol") != "tcp" or item.get("family") != "ipv4":
            continue
        # /proc/net/tcp state 0A is LISTEN. Only listeners are reserved: these
        # are the endpoints for which a temporary bind(port=0) collision was
        # observed and the set stays compact enough for the sysctl interface.
        if item.get("state") != "0A":
            continue
        try:
            port = int(item.get("local_port", 0))
        except (TypeError, ValueError):
            continue
        if 1 <= port <= 65535:
            ports.add(port)
    return ports


def atomic_write_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def write_text(path: Optional[Path], text: str) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text.rstrip("\n") + "\n", encoding="utf-8")


def prepare(args: argparse.Namespace) -> int:
    ports = captured_ipv4_tcp_listener_ports(args.capture_state)
    original_text = read_sysctl(args.sysctl_path)
    original_ports = parse_port_set(original_text)
    requested_text = format_port_set(original_ports | ports)

    if len(requested_text.encode("ascii")) > args.max_value_bytes:
        raise ReservationError(
            "merged ip_local_reserved_ports value is too large: "
            f"{len(requested_text.encode('ascii'))} bytes exceeds "
            f"configured limit {args.max_value_bytes}"
        )

    if ports:
        write_sysctl(args.sysctl_path, requested_text)
        applied_text = read_sysctl(args.sysctl_path)
        applied_ports = parse_port_set(applied_text)
        missing = (original_ports | ports) - applied_ports
        if missing:
            # Best effort rollback before reporting failure.
            try:
                write_sysctl(args.sysctl_path, original_text)
            except ReservationError:
                pass
            raise ReservationError(
                "kernel did not retain all requested reserved ports: "
                + format_port_set(missing)
            )
    else:
        applied_text = original_text
        applied_ports = original_ports

    added_ports = ports - original_ports
    state = {
        "format_version": 1,
        "sysctl_path": str(args.sysctl_path),
        "capture_state": str(args.capture_state),
        "original_value": original_text,
        "applied_value": applied_text,
        "captured_listener_ports": sorted(ports),
        "added_ports": sorted(added_ports),
        "prepared": True,
        "released": False,
    }
    atomic_write_json(args.state, state)
    write_text(args.ports_output, format_port_set(ports))
    write_text(args.original_output, original_text)
    write_text(args.applied_output, applied_text)

    if ports:
        print(
            "[restore-port-reservation] Reserved captured IPv4 TCP listener ports: "
            + format_port_set(ports),
            flush=True,
        )
    else:
        print(
            "[restore-port-reservation] No captured IPv4 TCP listener ports required reservation.",
            flush=True,
        )
    return 0


def release(args: argparse.Namespace) -> int:
    try:
        state = json.loads(args.state.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ReservationError(f"cannot read reservation state {args.state}: {exc}") from exc
    if state.get("format_version") != 1 or not state.get("prepared"):
        raise ReservationError(f"invalid reservation state in {args.state}")
    if state.get("released"):
        print("[restore-port-reservation] Reservation was already released.", flush=True)
        return 0

    sysctl_path = Path(str(state.get("sysctl_path", "")))
    if args.sysctl_path is not None and sysctl_path != args.sysctl_path:
        raise ReservationError(
            f"reservation state targets {sysctl_path}, not requested {args.sysctl_path}"
        )

    original_text = str(state.get("original_value", ""))
    applied_text = str(state.get("applied_value", ""))
    original_ports = parse_port_set(original_text)
    applied_ports = parse_port_set(applied_text)
    added_ports = {int(value) for value in state.get("added_ports", [])}
    current_text = read_sysctl(sysctl_path)
    current_ports = parse_port_set(current_text)

    concurrent_change = current_ports != applied_ports
    if not concurrent_change:
        restored_text = original_text
    else:
        # Preserve ports added externally while this transaction was active,
        # remove only this run's additions, and restore anything present in the
        # original setting. This avoids clobbering an unrelated administrator.
        restored_text = format_port_set((current_ports - added_ports) | original_ports)

    write_sysctl(sysctl_path, restored_text)
    verified_text = read_sysctl(sysctl_path)
    verified_ports = parse_port_set(verified_text)
    expected_ports = parse_port_set(restored_text)
    if verified_ports != expected_ports:
        raise ReservationError(
            f"failed to verify restored reserved-port setting at {sysctl_path}"
        )

    state["released"] = True
    state["release_concurrent_change_detected"] = concurrent_change
    state["release_value"] = verified_text
    atomic_write_json(args.state, state)
    write_text(args.release_output, verified_text)

    if concurrent_change:
        print(
            "[restore-port-reservation] External sysctl change detected; "
            "removed this run's additions while preserving unrelated changes.",
            flush=True,
        )
    else:
        print(
            "[restore-port-reservation] Restored the exact previous "
            "ip_local_reserved_ports value.",
            flush=True,
        )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare", help="reserve captured listener ports")
    prepare_parser.add_argument("--capture-state", type=Path, required=True)
    prepare_parser.add_argument("--state", type=Path, required=True)
    prepare_parser.add_argument("--sysctl-path", type=Path, required=True)
    prepare_parser.add_argument("--ports-output", type=Path)
    prepare_parser.add_argument("--original-output", type=Path)
    prepare_parser.add_argument("--applied-output", type=Path)
    prepare_parser.add_argument("--max-value-bytes", type=int, default=4095)
    prepare_parser.set_defaults(func=prepare)

    release_parser = subparsers.add_parser("release", help="restore the previous setting")
    release_parser.add_argument("--state", type=Path, required=True)
    release_parser.add_argument("--sysctl-path", type=Path)
    release_parser.add_argument("--release-output", type=Path)
    release_parser.set_defaults(func=release)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except ReservationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
