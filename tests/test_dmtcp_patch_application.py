#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

"""Validate that the versioned unified DMTCP patch is structurally applicable."""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parent.parent
PATCH = (
    ROOT
    / "patches"
    / "dmtcp-6896e12276a9fe449edb0cf206203ce01b19efe6"
    / "kernelbufferdrainer-duplex-refill.patch"
)
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
PATCH_COMMAND = shutil.which("patch")


def synthesize_old_file(patch_text: str) -> list[str]:
    """Build a synthetic old-side source file from every unified-diff hunk."""

    lines = patch_text.splitlines()
    hunks: list[tuple[int, list[str]]] = []
    index = 0
    maximum = 0
    while index < len(lines):
        match = HUNK.match(lines[index])
        if not match:
            index += 1
            continue
        old_start = int(match.group(1))
        old_count = int(match.group(2) or "1")
        index += 1
        body: list[str] = []
        while index < len(lines) and not lines[index].startswith("@@ "):
            if lines[index].startswith("diff "):
                break
            marker = lines[index][:1]
            if marker in {" ", "-"}:
                body.append(lines[index][1:])
            elif marker == "\\":
                pass
            index += 1
        assert len(body) == old_count, (
            f"hunk at old line {old_start} declares {old_count} lines "
            f"but contains {len(body)} old-side lines"
        )
        hunks.append((old_start, body))
        maximum = max(maximum, old_start - 1 + old_count)

    assert hunks, "patch contains no unified-diff hunks"
    source = [f"// synthetic filler line {number + 1}" for number in range(maximum)]
    occupied: set[int] = set()
    for old_start, body in hunks:
        for offset, text in enumerate(body):
            position = old_start - 1 + offset
            assert position not in occupied or source[position] == text, (
                "overlapping synthetic hunks disagree"
            )
            source[position] = text
            occupied.add(position)
    return source


def test_patch_applies_with_zero_fuzz(tmp_path: Path) -> None:
    if PATCH_COMMAND is None:
        pytest.skip("the system 'patch' command is not installed")

    assert PATCH.is_file(), f"missing patch asset: {PATCH}"
    patch_text = PATCH.read_text(encoding="utf-8")
    source = tmp_path / "src/plugin/ipc/socket/kernelbufferdrainer.cpp"
    source.parent.mkdir(parents=True)
    source.write_text(
        "\n".join(synthesize_old_file(patch_text)) + "\n",
        encoding="utf-8",
    )

    completed = subprocess.run(
        [PATCH_COMMAND, "--batch", "--forward", "--fuzz=0", "-p1", "-i", str(PATCH)],
        cwd=tmp_path,
        text=True,
        capture_output=True,
        check=False,
        timeout=15,
    )
    assert completed.returncode == 0, (
        "unified patch did not apply with zero fuzz\n"
        f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
    )

    patched = source.read_text(encoding="utf-8")
    expected_markers = (
        "receive-capacity-aware nonblocking",
        "SO_RCVBUFFORCE",
        "stream-refill receive buffer is too small",
        "failed to restore stream-refill receive buffer size",
    )
    missing = [marker for marker in expected_markers if marker not in patched]
    assert not missing, f"patched source lacks markers: {missing}"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-p", "no:cacheprovider"]))
