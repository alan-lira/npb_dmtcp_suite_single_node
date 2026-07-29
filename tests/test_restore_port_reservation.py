#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

"""Controlled tests for transactional restore-port reservation."""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import json
from pathlib import Path
import subprocess
import sys

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
HELPER = REPO_ROOT / "scripts" / "restore_port_reservation.py"


def run_helper(*args: str) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        [sys.executable, str(HELPER), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=15,
    )
    assert completed.returncode == 0, (
        f"helper failed ({completed.returncode})\n"
        f"stdout:\n{completed.stdout}\n"
        f"stderr:\n{completed.stderr}"
    )
    return completed


def write_capture(path: Path, listener_ports: list[int]) -> None:
    sockets: list[dict[str, object]] = []
    inode = 100
    for port in listener_ports:
        sockets.append(
            {
                "inode": inode,
                "protocol": "tcp",
                "family": "ipv4",
                "sock_type": "stream",
                "local_address": "0.0.0.0",
                "local_port": port,
                "remote_address": "0.0.0.0",
                "remote_port": 0,
                "state": "0A",
                "unix_path": None,
                "unix_abstract": False,
                "filesystem_device": None,
                "filesystem_inode": None,
                "filesystem_uid": None,
                "owners": [[1234, 5678]],
            }
        )
        inode += 1

    # Established IPv4 connections and IPv6 listeners must not be reserved.
    sockets.extend(
        [
            {
                "inode": inode,
                "protocol": "tcp",
                "family": "ipv4",
                "sock_type": "stream",
                "local_address": "127.0.0.1",
                "local_port": 3333,
                "remote_address": "127.0.0.1",
                "remote_port": 4444,
                "state": "01",
                "unix_path": None,
                "unix_abstract": False,
                "filesystem_device": None,
                "filesystem_inode": None,
                "filesystem_uid": None,
                "owners": [],
            },
            {
                "inode": inode + 1,
                "protocol": "tcp",
                "family": "ipv6",
                "sock_type": "stream",
                "local_address": "::",
                "local_port": 5555,
                "remote_address": "::",
                "remote_port": 0,
                "state": "0A",
                "unix_path": None,
                "unix_abstract": False,
                "filesystem_device": None,
                "filesystem_inode": None,
                "filesystem_uid": None,
                "owners": [],
            },
        ]
    )
    path.write_text(
        json.dumps(
            {
                "format_version": 1,
                "captured_at": "2026-07-27T00:00:00+0000",
                "boot_id": "unknown",
                "uid": 0,
                "processes": [],
                "sockets": sockets,
            }
        )
        + "\n",
        encoding="utf-8",
    )


def test_prepare_merges_listeners_and_release_restores_exact_value(tmp_path: Path) -> None:
    capture = tmp_path / "capture.json"
    sysctl = tmp_path / "ip_local_reserved_ports"
    state = tmp_path / "state.json"
    ports_output = tmp_path / "ports.txt"
    original_output = tmp_path / "original.txt"
    applied_output = tmp_path / "applied.txt"
    released_output = tmp_path / "released.txt"

    write_capture(capture, [2001, 2002])
    sysctl.write_text("1000-1002,2000\n", encoding="utf-8")
    run_helper(
        "prepare",
        "--capture-state",
        str(capture),
        "--state",
        str(state),
        "--sysctl-path",
        str(sysctl),
        "--ports-output",
        str(ports_output),
        "--original-output",
        str(original_output),
        "--applied-output",
        str(applied_output),
    )

    assert sysctl.read_text(encoding="utf-8").strip() == "1000-1002,2000-2002"
    assert ports_output.read_text(encoding="utf-8").strip() == "2001-2002"
    assert original_output.read_text(encoding="utf-8").strip() == "1000-1002,2000"
    assert applied_output.read_text(encoding="utf-8").strip() == "1000-1002,2000-2002"

    run_helper(
        "release",
        "--state",
        str(state),
        "--sysctl-path",
        str(sysctl),
        "--release-output",
        str(released_output),
    )
    assert sysctl.read_text(encoding="utf-8").strip() == "1000-1002,2000"
    assert released_output.read_text(encoding="utf-8").strip() == "1000-1002,2000"

    state_data = json.loads(state.read_text(encoding="utf-8"))
    assert state_data["released"] is True
    assert state_data["release_concurrent_change_detected"] is False


def test_release_preserves_concurrent_external_additions(tmp_path: Path) -> None:
    capture = tmp_path / "capture.json"
    sysctl = tmp_path / "ip_local_reserved_ports"
    state = tmp_path / "state.json"

    write_capture(capture, [2000])
    sysctl.write_text("1000\n", encoding="utf-8")
    run_helper(
        "prepare",
        "--capture-state",
        str(capture),
        "--state",
        str(state),
        "--sysctl-path",
        str(sysctl),
    )

    sysctl.write_text("1000,2000,3000\n", encoding="utf-8")
    run_helper(
        "release",
        "--state",
        str(state),
        "--sysctl-path",
        str(sysctl),
    )

    assert sysctl.read_text(encoding="utf-8").strip() == "1000,3000"
    state_data = json.loads(state.read_text(encoding="utf-8"))
    assert state_data["release_concurrent_change_detected"] is True
    assert state_data["release_value"] == "1000,3000"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-p", "no:cacheprovider"]))
