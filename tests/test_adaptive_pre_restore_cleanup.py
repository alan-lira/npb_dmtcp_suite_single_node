#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

"""Controlled integration tests for adaptive_pre_restore_cleanup.py."""

from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
from typing import Dict


SCRIPT_DIR = Path(__file__).resolve().parent.parent.joinpath("scripts")
HELPER = SCRIPT_DIR / "adaptive_pre_restore_cleanup.py"


SOCKET_CHILD = r'''
import json
import os
from pathlib import Path
import signal
import socket
import sys
import time

unix_path = sys.argv[1]
abstract_name = sys.argv[2]

tcp_listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
tcp_listener.bind(("127.0.0.1", 0))
tcp_listener.listen(1)

udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp_socket.bind(("127.0.0.1", 0))

unix_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
unix_socket.bind(unix_path)
unix_socket.listen(1)

abstract_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
abstract_socket.bind("\0" + abstract_name)
abstract_socket.listen(1)

print(json.dumps({
    "pid": os.getpid(),
    "tcp_port": tcp_listener.getsockname()[1],
    "udp_port": udp_socket.getsockname()[1],
    "unix_path": unix_path,
    "abstract_name": abstract_name,
}), flush=True)

running = True

def stop(_signum, _frame):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
while running:
    time.sleep(0.05)

for sock in (tcp_listener, udp_socket, unix_socket, abstract_socket):
    sock.close()
'''


TREE_WRAPPER = r'''
import os
import signal
import subprocess
import sys
import time

child = subprocess.Popen(
    [sys.executable, "-c", sys.argv[1], *sys.argv[2:]],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
assert child.stdout is not None
print(child.stdout.readline().strip(), flush=True)

running = True
def stop(_signum, _frame):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)
while running:
    time.sleep(0.05)
# Deliberately do not terminate the descendant. The cleanup helper must use
# the captured tree identity to terminate it safely after this wrapper exits.
'''


TCP_CHILD = r'''
import json
import os
import signal
import socket
import sys
import time

requested_port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", requested_port))
sock.listen(1)
print(json.dumps({"pid": os.getpid(), "tcp_port": sock.getsockname()[1]}), flush=True)

running = True

def stop(_signum, _frame):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)
while running:
    time.sleep(0.05)
sock.close()
'''


def start_child(code: str, *args: str) -> tuple[subprocess.Popen[str], Dict[str, object]]:
    process = subprocess.Popen(
        [sys.executable, "-c", code, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert process.stdout is not None
    line = process.stdout.readline().strip()
    if not line:
        stderr = process.stderr.read() if process.stderr is not None else ""
        raise RuntimeError(f"socket child failed to start: {stderr}")
    return process, json.loads(line)


def start_tree_child(code: str, *args: str) -> tuple[subprocess.Popen[str], Dict[str, object]]:
    process = subprocess.Popen(
        [sys.executable, "-c", TREE_WRAPPER, code, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert process.stdout is not None
    line = process.stdout.readline().strip()
    if not line:
        stderr = process.stderr.read() if process.stderr is not None else ""
        raise RuntimeError(f"process-tree wrapper failed to start: {stderr}")
    return process, json.loads(line)


def run(*args: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        [sys.executable, str(HELPER), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != expected:
        raise AssertionError(
            f"command returned {completed.returncode}, expected {expected}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed


def terminate(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def test_successful_cleanup(temp_root: Path) -> None:
    unix_path = temp_root / "captured.sock"
    abstract_name = f"npb-dmtcp-cleanup-{os.getpid()}-{time.time_ns()}"
    child, metadata = start_tree_child(SOCKET_CHILD, str(unix_path), abstract_name)
    state = temp_root / "success-state.json"
    process_report = temp_root / "success-processes.tsv"
    socket_report = temp_root / "success-sockets.tsv"
    try:
        run(
            "capture",
            "--root-pid",
            str(child.pid),
            "--state",
            str(state),
            "--process-report",
            str(process_report),
            "--socket-report",
            str(socket_report),
        )
        captured = json.loads(state.read_text(encoding="utf-8"))
        if len(captured["processes"]) < 2:
            raise AssertionError("descendant process was not captured as part of the tree")
        protocols = {item["protocol"] for item in captured["sockets"]}
        if not {"tcp", "udp", "unix"}.issubset(protocols):
            raise AssertionError(f"missing captured protocols: {protocols}")

        completed = run(
            "cleanup",
            "--state",
            str(state),
            "--metrics-dir",
            str(temp_root),
            "--timeout",
            "10",
            "--poll",
            "0.05",
            "--force-kill-after",
            "0.15",
            "--force-kill-grace",
            "0.20",
            "--final-grace",
            "0.05",
            "--report-interval",
            "0.10",
        )
        child.wait(timeout=3)
        if unix_path.exists():
            raise AssertionError("captured stale Unix socket path was not removed")
        if (temp_root / "pre_restore_cleanup_status.txt").read_text().strip() != "SUCCESS":
            raise AssertionError("cleanup did not write SUCCESS status")
        if "All captured socket endpoints are reusable" not in completed.stdout:
            raise AssertionError("endpoint verification was not reported")
        print("[OK] adaptive cleanup releases captured processes and TCP/UDP/Unix sockets")
    finally:
        terminate(child)
        try:
            unix_path.unlink()
        except FileNotFoundError:
            pass


def test_unrelated_owner_is_not_killed(temp_root: Path) -> None:
    original, original_meta = start_child(TCP_CHILD, "0")
    port = int(original_meta["tcp_port"])
    state = temp_root / "conflict-state.json"
    process_report = temp_root / "conflict-processes.tsv"
    socket_report = temp_root / "conflict-sockets.tsv"
    unrelated: subprocess.Popen[str] | None = None
    try:
        run(
            "capture",
            "--root-pid",
            str(original.pid),
            "--state",
            str(state),
            "--process-report",
            str(process_report),
            "--socket-report",
            str(socket_report),
        )
        terminate(original)
        unrelated, _ = start_child(TCP_CHILD, str(port))

        completed = run(
            "cleanup",
            "--state",
            str(state),
            "--metrics-dir",
            str(temp_root / "conflict-metrics"),
            "--timeout",
            "5",
            "--poll",
            "0.05",
            "--force-kill-after",
            "0",
            "--force-kill-grace",
            "0",
            "--final-grace",
            "0",
            "--report-interval",
            "0.10",
            expected=20,
        )
        if unrelated.poll() is not None:
            raise AssertionError("cleanup killed an unrelated endpoint owner")
        if "unrelated process" not in completed.stderr:
            raise AssertionError("unrelated endpoint conflict was not diagnosed")
        print("[OK] adaptive cleanup aborts without killing an unrelated socket owner")
    finally:
        terminate(original)
        if unrelated is not None:
            terminate(unrelated)


def test_pid_start_time_mismatch_is_not_signaled(temp_root: Path) -> None:
    unrelated, _ = start_child(TCP_CHILD, "0")
    state = temp_root / "pid-reuse-state.json"
    process_report = temp_root / "pid-reuse-processes.tsv"
    socket_report = temp_root / "pid-reuse-sockets.tsv"
    metrics = temp_root / "pid-reuse-metrics"
    try:
        run(
            "capture",
            "--root-pid",
            str(unrelated.pid),
            "--state",
            str(state),
            "--process-report",
            str(process_report),
            "--socket-report",
            str(socket_report),
        )
        captured = json.loads(state.read_text(encoding="utf-8"))
        captured["processes"][0]["start_time_ticks"] += 1
        captured["sockets"] = []
        state.write_text(json.dumps(captured), encoding="utf-8")
        run(
            "cleanup",
            "--state",
            str(state),
            "--metrics-dir",
            str(metrics),
            "--timeout",
            "2",
            "--poll",
            "0.05",
            "--force-kill-after",
            "0",
            "--force-kill-grace",
            "0",
            "--final-grace",
            "0",
            "--report-interval",
            "0.1",
        )
        if unrelated.poll() is not None:
            raise AssertionError("PID with a different start time was signaled")
        print("[OK] PID reuse protection leaves a mismatched PID/start-time process untouched")
    finally:
        terminate(unrelated)



def main() -> int:
    if not Path("/proc/net/tcp").is_file():
        print("ERROR: Linux /proc socket tables are required", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory(prefix="npb-dmtcp-cleanup-test-") as temp_dir:
        temp_root = Path(temp_dir)
        test_successful_cleanup(temp_root)
        test_unrelated_owner_is_not_killed(temp_root)
        test_pid_start_time_mismatch_is_not_signaled(temp_root)
    print("[OK] controlled adaptive pre-restore cleanup tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
