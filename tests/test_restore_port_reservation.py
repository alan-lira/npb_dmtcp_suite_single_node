#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0

"""Controlled tests for transactional restore-port reservation."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile


REPO_ROOT = Path(__file__).resolve().parent.parent
HELPER = REPO_ROOT / "scripts" / "restore_port_reservation.py"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        [str(HELPER), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"helper failed ({completed.returncode})\n"
            f"stdout:\n{completed.stdout}\n"
            f"stderr:\n{completed.stderr}"
        )
    return completed


def write_capture(path: Path, listener_ports: list[int]) -> None:
    sockets = []
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
    # These must not be reserved.
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


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="restore-port-reservation-") as temporary:
        root = Path(temporary)
        capture = root / "capture.json"
        sysctl = root / "ip_local_reserved_ports"
        state = root / "state.json"
        ports_output = root / "ports.txt"
        original_output = root / "original.txt"
        applied_output = root / "applied.txt"
        released_output = root / "released.txt"

        write_capture(capture, [2001, 2002])
        sysctl.write_text("1000-1002,2000\n", encoding="utf-8")
        run(
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
        if sysctl.read_text(encoding="utf-8").strip() != "1000-1002,2000-2002":
            raise AssertionError("captured listeners were not merged correctly")
        if ports_output.read_text(encoding="utf-8").strip() != "2001-2002":
            raise AssertionError("listener-port diagnostics are incorrect")
        run(
            "release",
            "--state",
            str(state),
            "--sysctl-path",
            str(sysctl),
            "--release-output",
            str(released_output),
        )
        if sysctl.read_text(encoding="utf-8").strip() != "1000-1002,2000":
            raise AssertionError("exact previous reserved-port value was not restored")

        # A concurrent external addition must survive release.
        state2 = root / "state2.json"
        sysctl.write_text("1000\n", encoding="utf-8")
        write_capture(capture, [2000])
        run(
            "prepare",
            "--capture-state",
            str(capture),
            "--state",
            str(state2),
            "--sysctl-path",
            str(sysctl),
        )
        sysctl.write_text("1000,2000,3000\n", encoding="utf-8")
        run(
            "release",
            "--state",
            str(state2),
            "--sysctl-path",
            str(sysctl),
        )
        if sysctl.read_text(encoding="utf-8").strip() != "1000,3000":
            raise AssertionError("external reserved-port addition was not preserved")
        state_data = json.loads(state2.read_text(encoding="utf-8"))
        if not state_data.get("release_concurrent_change_detected"):
            raise AssertionError("concurrent sysctl change was not recorded")

    print("[OK] restore-port reservation merges, restores, and preserves external changes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
