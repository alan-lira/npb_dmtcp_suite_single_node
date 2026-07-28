#!/usr/bin/env python3

"""Validate that the versioned unified DMTCP patch is structurally applicable."""

from __future__ import annotations

import re
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
PATCH = (
    ROOT
    / "patches"
    / "dmtcp-6896e12276a9fe449edb0cf206203ce01b19efe6"
    / "kernelbufferdrainer-duplex-refill.patch"
)
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def synthesize_old_file(patch_text: str) -> list[str]:
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
        if len(body) != old_count:
            raise AssertionError(
                f"hunk at old line {old_start} declares {old_count} lines "
                f"but contains {len(body)} old-side lines"
            )
        hunks.append((old_start, body))
        maximum = max(maximum, old_start - 1 + old_count)

    source = [f"// synthetic filler line {number + 1}" for number in range(maximum)]
    occupied: set[int] = set()
    for old_start, body in hunks:
        for offset, text in enumerate(body):
            position = old_start - 1 + offset
            if position in occupied and source[position] != text:
                raise AssertionError("overlapping synthetic hunks disagree")
            source[position] = text
            occupied.add(position)
    return source


def main() -> int:
    patch_text = PATCH.read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="dmtcp-patch-apply-") as temp_text:
        temp = Path(temp_text)
        source = temp / "src/plugin/ipc/socket/kernelbufferdrainer.cpp"
        source.parent.mkdir(parents=True)
        source.write_text(
            "\n".join(synthesize_old_file(patch_text)) + "\n",
            encoding="utf-8",
        )
        completed = subprocess.run(
            ["patch", "--batch", "--forward", "--fuzz=0", "-p1", "-i", str(PATCH)],
            cwd=temp,
            text=True,
            capture_output=True,
            check=False,
        )
        if completed.returncode != 0:
            raise AssertionError(
                "unified patch did not apply with zero fuzz\n"
                f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
            )
        patched = source.read_text(encoding="utf-8")
        for marker in (
            "receive-capacity-aware nonblocking",
            "SO_RCVBUFFORCE",
            "stream-refill receive buffer is too small",
            "failed to restore stream-refill receive buffer size",
        ):
            if marker not in patched:
                raise AssertionError(f"patched source lacks marker: {marker}")

    print("Versioned DMTCP refill patch applies with zero fuzz and contains capacity markers.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
