#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0

"""Controlled tests for restore-scoped TCP receive-window transactions."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile


REPO_ROOT = Path(__file__).resolve().parent.parent
HELPER = REPO_ROOT / "scripts" / "restore_tcp_receive_window.py"


def run(*args: str, expect_success: bool = True) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        [str(HELPER), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if expect_success and completed.returncode != 0:
        raise AssertionError(
            f"helper failed ({completed.returncode})\n"
            f"stdout:\n{completed.stdout}\n"
            f"stderr:\n{completed.stderr}"
        )
    if not expect_success and completed.returncode == 0:
        raise AssertionError("helper unexpectedly succeeded")
    return completed


def prepare(root: Path, rmem_value: str, tcp_rmem_value: str) -> tuple[Path, Path, Path]:
    rmem = root / "rmem_max"
    tcp_rmem = root / "tcp_rmem"
    state = root / "state.json"
    rmem.write_text(rmem_value + "\n", encoding="utf-8")
    tcp_rmem.write_text(tcp_rmem_value + "\n", encoding="utf-8")
    run(
        "prepare",
        "--state",
        str(state),
        "--rmem-max-path",
        str(rmem),
        "--tcp-rmem-path",
        str(tcp_rmem),
        "--target-rmem-max",
        "16777216",
        "--target-tcp-rmem",
        "4096 4194304 16777216",
    )
    return rmem, tcp_rmem, state


def release(rmem: Path, tcp_rmem: Path, state: Path) -> None:
    run(
        "release",
        "--state",
        str(state),
        "--rmem-max-path",
        str(rmem),
        "--tcp-rmem-path",
        str(tcp_rmem),
    )


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="restore-tcp-receive-window-") as temporary:
        root = Path(temporary)

        # The validated floors are applied and the exact old values are restored.
        case1 = root / "case1"
        case1.mkdir()
        rmem, tcp_rmem, state = prepare(case1, "212992", "4096 131072 6291456")
        if rmem.read_text(encoding="utf-8").strip() != "16777216":
            raise AssertionError("net.core.rmem_max floor was not applied")
        if tcp_rmem.read_text(encoding="utf-8").strip() != "4096 4194304 16777216":
            raise AssertionError("net.ipv4.tcp_rmem floor was not applied")
        release(rmem, tcp_rmem, state)
        if rmem.read_text(encoding="utf-8").strip() != "212992":
            raise AssertionError("original net.core.rmem_max was not restored")
        if tcp_rmem.read_text(encoding="utf-8").strip() != "4096 131072 6291456":
            raise AssertionError("original net.ipv4.tcp_rmem was not restored")

        # Existing host settings above the validated floor must not be lowered.
        case2 = root / "case2"
        case2.mkdir()
        rmem, tcp_rmem, state = prepare(
            case2,
            "33554432",
            "8192 8388608 33554432",
        )
        if rmem.read_text(encoding="utf-8").strip() != "33554432":
            raise AssertionError("higher host rmem_max was lowered")
        if tcp_rmem.read_text(encoding="utf-8").strip() != "8192 8388608 33554432":
            raise AssertionError("higher host tcp_rmem was lowered")
        release(rmem, tcp_rmem, state)

        # External changes are detected, but the explicit contract is to restore
        # the exact values captured before this restore transaction.
        case3 = root / "case3"
        case3.mkdir()
        rmem, tcp_rmem, state = prepare(case3, "212992", "4096 131072 6291456")
        rmem.write_text("33554432\n", encoding="utf-8")
        tcp_rmem.write_text("4096 8388608 33554432\n", encoding="utf-8")
        release(rmem, tcp_rmem, state)
        state_data = json.loads(state.read_text(encoding="utf-8"))
        if not state_data.get("release_concurrent_change_detected"):
            raise AssertionError("external sysctl change was not detected")
        if rmem.read_text(encoding="utf-8").strip() != "212992":
            raise AssertionError("exact original rmem_max was not restored after external change")
        if tcp_rmem.read_text(encoding="utf-8").strip() != "4096 131072 6291456":
            raise AssertionError("exact original tcp_rmem was not restored after external change")

        # A signal during setup may leave a valid partial state. Release must
        # still restore the recorded values exactly.
        partial = root / "partial"
        partial.mkdir()
        partial_rmem = partial / "rmem_max"
        partial_tcp = partial / "tcp_rmem"
        partial_state = partial / "state.json"
        partial_rmem.write_text("16777216\n", encoding="utf-8")
        partial_tcp.write_text("4096 4194304 16777216\n", encoding="utf-8")
        partial_state.write_text(
            json.dumps(
                {
                    "format_version": 1,
                    "rmem_max_path": str(partial_rmem),
                    "tcp_rmem_path": str(partial_tcp),
                    "original_rmem_max": "212992",
                    "original_tcp_rmem": "4096 131072 6291456",
                    "applied_rmem_max": "16777216",
                    "applied_tcp_rmem": "4096 4194304 16777216",
                    "prepare_complete": False,
                    "release_complete": False,
                }
            )
            + "\n",
            encoding="utf-8",
        )
        release(partial_rmem, partial_tcp, partial_state)
        if partial_rmem.read_text(encoding="utf-8").strip() != "212992":
            raise AssertionError("partial transaction did not restore rmem_max")
        if partial_tcp.read_text(encoding="utf-8").strip() != "4096 131072 6291456":
            raise AssertionError("partial transaction did not restore tcp_rmem")

        # Invalid target ordering must be rejected before a transaction starts.
        invalid = root / "invalid"
        invalid.mkdir()
        rmem = invalid / "rmem_max"
        tcp_rmem = invalid / "tcp_rmem"
        state = invalid / "state.json"
        rmem.write_text("212992\n", encoding="utf-8")
        tcp_rmem.write_text("4096 131072 6291456\n", encoding="utf-8")
        run(
            "prepare",
            "--state",
            str(state),
            "--rmem-max-path",
            str(rmem),
            "--tcp-rmem-path",
            str(tcp_rmem),
            "--target-rmem-max",
            "16777216",
            "--target-tcp-rmem",
            "4096 16777216 4194304",
            expect_success=False,
        )
        if rmem.read_text(encoding="utf-8").strip() != "212992":
            raise AssertionError("invalid transaction modified rmem_max")
        if tcp_rmem.read_text(encoding="utf-8").strip() != "4096 131072 6291456":
            raise AssertionError("invalid transaction modified tcp_rmem")

    print("[OK] restore TCP receive-window tuning applies floors and restores exact prior values")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
