#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

"""Controlled integration tests for adaptive_pre_restore_cleanup.py."""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time

import pytest


SCRIPT_DIR = Path(__file__).resolve().parent.parent / "scripts"
HELPER = SCRIPT_DIR / "adaptive_pre_restore_cleanup.py"

pytestmark = pytest.mark.skipif(
    not Path("/proc/net/tcp").is_file(),
    reason="Linux /proc socket tables are required",
)


SOCKET_CHILD = r'''
import json
import os
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


def _read_startup_metadata(
    process: subprocess.Popen[str], label: str, timeout: float = 5.0
) -> dict[str, object]:
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        if not selector.select(timeout):
            raise RuntimeError(f"{label} did not report startup within {timeout} seconds")
        line = process.stdout.readline().strip()
    finally:
        selector.close()

    if not line:
        stderr = process.stderr.read() if process.stderr is not None else ""
        raise RuntimeError(f"{label} failed to start: {stderr}")
    return json.loads(line)


def start_child(code: str, *args: str) -> tuple[subprocess.Popen[str], dict[str, object]]:
    process = subprocess.Popen(
        [sys.executable, "-c", code, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return process, _read_startup_metadata(process, "socket child")


def start_tree_child(
    code: str, *args: str
) -> tuple[subprocess.Popen[str], dict[str, object]]:
    process = subprocess.Popen(
        [sys.executable, "-c", TREE_WRAPPER, code, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return process, _read_startup_metadata(process, "process-tree wrapper")


def run_helper(*args: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        [sys.executable, str(HELPER), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=20,
    )
    assert completed.returncode == expected, (
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


def terminate_pid(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def test_successful_cleanup(tmp_path: Path) -> None:
    unix_path = tmp_path / "captured.sock"
    abstract_name = f"npb-dmtcp-cleanup-{os.getpid()}-{time.time_ns()}"
    child, metadata = start_tree_child(SOCKET_CHILD, str(unix_path), abstract_name)
    descendant_pid = int(metadata["pid"])
    state = tmp_path / "success-state.json"
    process_report = tmp_path / "success-processes.tsv"
    socket_report = tmp_path / "success-sockets.tsv"
    try:
        run_helper(
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
        assert len(captured["processes"]) >= 2, (
            "descendant process was not captured as part of the tree"
        )
        protocols = {item["protocol"] for item in captured["sockets"]}
        assert {"tcp", "udp", "unix"} <= protocols, (
            f"missing captured protocols: {protocols}"
        )

        completed = run_helper(
            "cleanup",
            "--state",
            str(state),
            "--metrics-dir",
            str(tmp_path),
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
        assert not unix_path.exists(), "captured stale Unix socket path was not removed"
        assert (
            tmp_path / "pre_restore_cleanup_status.txt"
        ).read_text(encoding="utf-8").strip() == "SUCCESS"
        assert "All captured socket endpoints are reusable" in completed.stdout
    finally:
        terminate(child)
        terminate_pid(descendant_pid)
        unix_path.unlink(missing_ok=True)


def test_unrelated_owner_is_not_killed(tmp_path: Path) -> None:
    original, original_meta = start_child(TCP_CHILD, "0")
    port = int(original_meta["tcp_port"])
    state = tmp_path / "conflict-state.json"
    process_report = tmp_path / "conflict-processes.tsv"
    socket_report = tmp_path / "conflict-sockets.tsv"
    unrelated: subprocess.Popen[str] | None = None
    try:
        run_helper(
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

        completed = run_helper(
            "cleanup",
            "--state",
            str(state),
            "--metrics-dir",
            str(tmp_path / "conflict-metrics"),
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
        assert unrelated.poll() is None, "cleanup killed an unrelated endpoint owner"
        assert "unrelated process" in completed.stderr
    finally:
        terminate(original)
        if unrelated is not None:
            terminate(unrelated)


def test_pid_start_time_mismatch_is_not_signaled(tmp_path: Path) -> None:
    unrelated, _ = start_child(TCP_CHILD, "0")
    state = tmp_path / "pid-reuse-state.json"
    process_report = tmp_path / "pid-reuse-processes.tsv"
    socket_report = tmp_path / "pid-reuse-sockets.tsv"
    metrics = tmp_path / "pid-reuse-metrics"
    try:
        run_helper(
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

        run_helper(
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
        assert unrelated.poll() is None, "PID with a different start time was signaled"
    finally:
        terminate(unrelated)


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-p", "no:cacheprovider"]))
