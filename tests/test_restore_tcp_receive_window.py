#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

"""Controlled tests for restore-scoped TCP receive-window transactions."""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
HELPER = REPO_ROOT / "scripts" / "restore_tcp_receive_window.py"
TARGET_RMEM_MAX = "16777216"
TARGET_TCP_RMEM = "4096 4194304 16777216"


def load_helper_module():
    spec = importlib.util.spec_from_file_location("restore_tcp_receive_window", HELPER)
    assert spec is not None and spec.loader is not None, f"cannot load helper module: {HELPER}"
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_helper(
    *args: str, expected_returncode: int = 0
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        [sys.executable, str(HELPER), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=15,
    )
    assert completed.returncode == expected_returncode, (
        f"helper returned {completed.returncode}, expected {expected_returncode}\n"
        f"stdout:\n{completed.stdout}\n"
        f"stderr:\n{completed.stderr}"
    )
    return completed


def prepare(root: Path, rmem_value: str, tcp_rmem_value: str) -> tuple[Path, Path, Path]:
    root.mkdir(parents=True, exist_ok=True)
    rmem = root / "rmem_max"
    tcp_rmem = root / "tcp_rmem"
    state = root / "state.json"
    rmem.write_text(rmem_value + "\n", encoding="utf-8")
    tcp_rmem.write_text(tcp_rmem_value + "\n", encoding="utf-8")
    run_helper(
        "prepare",
        "--state",
        str(state),
        "--rmem-max-path",
        str(rmem),
        "--tcp-rmem-path",
        str(tcp_rmem),
        "--target-rmem-max",
        TARGET_RMEM_MAX,
        "--target-tcp-rmem",
        TARGET_TCP_RMEM,
    )
    return rmem, tcp_rmem, state


def release(rmem: Path, tcp_rmem: Path, state: Path) -> None:
    run_helper(
        "release",
        "--state",
        str(state),
        "--rmem-max-path",
        str(rmem),
        "--tcp-rmem-path",
        str(tcp_rmem),
    )


def test_prepare_applies_floors_and_release_restores_originals(tmp_path: Path) -> None:
    rmem, tcp_rmem, state = prepare(
        tmp_path / "case", "212992", "4096 131072 6291456"
    )
    assert rmem.read_text(encoding="utf-8").strip() == TARGET_RMEM_MAX
    assert tcp_rmem.read_text(encoding="utf-8").strip() == TARGET_TCP_RMEM

    release(rmem, tcp_rmem, state)
    assert rmem.read_text(encoding="utf-8").strip() == "212992"
    assert tcp_rmem.read_text(encoding="utf-8").strip() == "4096 131072 6291456"


def test_prepare_never_lowers_higher_host_settings(tmp_path: Path) -> None:
    rmem, tcp_rmem, state = prepare(
        tmp_path / "case", "33554432", "8192 8388608 33554432"
    )
    assert rmem.read_text(encoding="utf-8").strip() == "33554432"
    assert tcp_rmem.read_text(encoding="utf-8").strip() == "8192 8388608 33554432"

    release(rmem, tcp_rmem, state)
    assert rmem.read_text(encoding="utf-8").strip() == "33554432"
    assert tcp_rmem.read_text(encoding="utf-8").strip() == "8192 8388608 33554432"


def test_release_treats_equivalent_tcp_rmem_whitespace_as_unchanged(
    tmp_path: Path,
) -> None:
    rmem, tcp_rmem, state = prepare(
        tmp_path / "case", "212992", "4096 131072 6291456"
    )
    tcp_rmem.write_text("4096\t4194304\t16777216\n", encoding="utf-8")

    release(rmem, tcp_rmem, state)
    state_data = json.loads(state.read_text(encoding="utf-8"))
    assert state_data["release_concurrent_change_detected"] is False


def test_verified_write_normalizes_kernel_whitespace(tmp_path: Path) -> None:
    helper = load_helper_module()
    tcp_rmem = tmp_path / "kernel_formatted_tcp_rmem"
    tcp_rmem.write_text("4096\t131072\t6291456\n", encoding="utf-8")

    original_write_value = helper.write_value

    def kernel_formatted_write(path: Path, value: str) -> None:
        if path == tcp_rmem:
            original_write_value(path, "\t".join(value.split()))
        else:
            original_write_value(path, value)

    helper.write_value = kernel_formatted_write
    try:
        helper.verified_write(
            tcp_rmem,
            TARGET_TCP_RMEM,
            "net.ipv4.tcp_rmem setup",
            normalize=helper.normalize_tcp_rmem,
        )
    finally:
        helper.write_value = original_write_value

    assert helper.normalize_tcp_rmem(tcp_rmem.read_text(encoding="utf-8")) == TARGET_TCP_RMEM


def test_release_detects_external_change_but_restores_exact_originals(
    tmp_path: Path,
) -> None:
    rmem, tcp_rmem, state = prepare(
        tmp_path / "case", "212992", "4096 131072 6291456"
    )
    rmem.write_text("33554432\n", encoding="utf-8")
    tcp_rmem.write_text("4096 8388608 33554432\n", encoding="utf-8")

    release(rmem, tcp_rmem, state)
    state_data = json.loads(state.read_text(encoding="utf-8"))
    assert state_data["release_concurrent_change_detected"] is True
    assert rmem.read_text(encoding="utf-8").strip() == "212992"
    assert tcp_rmem.read_text(encoding="utf-8").strip() == "4096 131072 6291456"


def test_release_recovers_valid_partial_transaction(tmp_path: Path) -> None:
    rmem = tmp_path / "rmem_max"
    tcp_rmem = tmp_path / "tcp_rmem"
    state = tmp_path / "state.json"
    rmem.write_text(TARGET_RMEM_MAX + "\n", encoding="utf-8")
    tcp_rmem.write_text(TARGET_TCP_RMEM + "\n", encoding="utf-8")
    state.write_text(
        json.dumps(
            {
                "format_version": 1,
                "rmem_max_path": str(rmem),
                "tcp_rmem_path": str(tcp_rmem),
                "original_rmem_max": "212992",
                "original_tcp_rmem": "4096 131072 6291456",
                "applied_rmem_max": TARGET_RMEM_MAX,
                "applied_tcp_rmem": TARGET_TCP_RMEM,
                "prepare_complete": False,
                "release_complete": False,
            }
        )
        + "\n",
        encoding="utf-8",
    )

    release(rmem, tcp_rmem, state)
    assert rmem.read_text(encoding="utf-8").strip() == "212992"
    assert tcp_rmem.read_text(encoding="utf-8").strip() == "4096 131072 6291456"


def test_invalid_target_order_is_rejected_without_modifying_files(
    tmp_path: Path,
) -> None:
    rmem = tmp_path / "rmem_max"
    tcp_rmem = tmp_path / "tcp_rmem"
    state = tmp_path / "state.json"
    rmem.write_text("212992\n", encoding="utf-8")
    tcp_rmem.write_text("4096 131072 6291456\n", encoding="utf-8")

    completed = run_helper(
        "prepare",
        "--state",
        str(state),
        "--rmem-max-path",
        str(rmem),
        "--tcp-rmem-path",
        str(tcp_rmem),
        "--target-rmem-max",
        TARGET_RMEM_MAX,
        "--target-tcp-rmem",
        "4096 16777216 4194304",
        expected_returncode=1,
    )
    assert "ERROR:" in completed.stderr
    assert rmem.read_text(encoding="utf-8").strip() == "212992"
    assert tcp_rmem.read_text(encoding="utf-8").strip() == "4096 131072 6291456"
    assert not state.exists()


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-p", "no:cacheprovider"]))
