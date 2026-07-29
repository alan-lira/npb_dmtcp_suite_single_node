#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0

"""Integration test for run_one.sh pre-run cleanup and resume markers."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
RUN_ONE = REPO_ROOT / "scripts" / "run_one.sh"


def make_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def run(command: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    # File-backed capture prevents short-lived descendant processes from
    # keeping PIPE file descriptors open after run_one.sh has exited.
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as stdout_file, \
         tempfile.TemporaryFile(mode="w+", encoding="utf-8") as stderr_file:
        completed = subprocess.run(
            command,
            cwd=REPO_ROOT,
            env=env,
            text=True,
            stdout=stdout_file,
            stderr=stderr_file,
            check=False,
            timeout=45,
        )
        stdout_file.seek(0)
        stderr_file.seek(0)
        stdout_text = stdout_file.read()
        stderr_text = stderr_file.read()

    result = subprocess.CompletedProcess(
        completed.args,
        completed.returncode,
        stdout_text,
        stderr_text,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"command failed with {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def test_run_resume_markers_and_cleanup() -> None:
    with tempfile.TemporaryDirectory(prefix="npb-run-resume-") as temp_text:
        temp = Path(temp_text)
        fake_bin = temp / "fake-bin"
        output = temp / "output"
        binaries = output / "binaries"
        results = output / "results"
        fake_bin.mkdir()
        binaries.mkdir(parents=True)
        results.mkdir(parents=True)

        counter = temp / "benchmark-count.txt"
        benchmark = binaries / "bt.D.x"
        make_executable(
            benchmark,
            "#!/usr/bin/env bash\n"
            f"count=0; [ ! -f {counter!s} ] || count=$(cat {counter!s}); "
            f"echo $((count + 1)) > {counter!s}\n"
            "echo 'Verification = SUCCESSFUL'\n",
        )

        make_executable(
            fake_bin / "mpirun",
            "#!/usr/bin/env bash\n"
            "if [ \"${1:-}\" = '-np' ]; then shift 2; fi\n"
            "exec \"$@\"\n",
        )
        for name in ("dmtcp_coordinator", "dmtcp_launch", "dmtcp_command"):
            make_executable(fake_bin / name, "#!/usr/bin/env bash\nexit 0\n")

        env_file = temp / "fake-env.sh"
        env_file.write_text(
            f'export PATH="{fake_bin}:$PATH"\n'
            'export DMTCP_SIGCKPT="30"\n',
            encoding="utf-8",
        )

        run_dir = results / "btD_np16_baseline_rep1"
        run_dir.mkdir()
        (run_dir / "incomplete-sentinel.txt").write_text("old\n", encoding="utf-8")

        env = os.environ.copy()
        env.update(
            {
                "ENV_FILE": str(env_file),
                "OUTPUT_ROOT": str(output),
                "BINARY_ROOT": str(binaries),
                "RESULTS_ROOT": str(results),
                "REQUIRE_WORKING_STACK": "false",
                "EXISTING_RUN_POLICY": "resume",
                "PROGRESS_INTERVAL_SECONDS": "1",
            }
        )

        first = run(
            ["bash", str(RUN_ONE), "bt", "16", "baseline", "1", "keep-checkpoints"],
            env,
        )
        marker = run_dir / "SUCCESS.marker"
        if not marker.is_file():
            raise AssertionError("SUCCESS.marker was not created")
        if "npb_verification=SUCCESSFUL" not in marker.read_text(encoding="utf-8"):
            raise AssertionError("SUCCESS.marker does not record NPB verification")
        if (run_dir / "incomplete-sentinel.txt").exists():
            raise AssertionError("incomplete run directory was not replaced")
        if not (run_dir / "pre_run_cleanup.log").is_file():
            raise AssertionError("pre_run_cleanup.log was not written")
        if counter.read_text(encoding="utf-8").strip() != "1":
            raise AssertionError("fake benchmark did not execute exactly once")
        if "Replacing incomplete run directory" not in first.stdout:
            raise AssertionError("resume did not report incomplete-directory replacement")

        second = run(
            ["bash", str(RUN_ONE), "bt", "16", "baseline", "1", "keep-checkpoints"],
            env,
        )
        if counter.read_text(encoding="utf-8").strip() != "1":
            raise AssertionError("completed run was executed again instead of skipped")
        if "Skipping successfully completed run" not in second.stdout:
            raise AssertionError("completed-run skip was not reported")



if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__]))
