#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

"""Keep README structure and public workflow references synchronized."""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

from pathlib import Path
import re

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
README_PATH = REPO_ROOT / "README.md"

EXCLUDED_PARTS = {
    ".git",
    ".idea",
    ".test-env",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    "__pycache__",
    "output",
}

PUBLIC_CONFIGURATION_VARIABLES = {
    "OUTPUT_ROOT",
    "BINARY_ROOT",
    "RESULTS_ROOT",
    "ENV_FILE",
    "NPB_ROOT",
    "NPB_CLASS",
    "REQUIRE_WORKING_STACK",
    "BENCHMARKS_TEXT",
    "MPI_RANKS_TEXT",
    "REPETITIONS",
    "BASELINE_REPETITIONS",
    "CR_REPETITIONS",
    "CHECKPOINT_PERCENTAGES_TEXT",
    "RUN_BASELINE",
    "EXISTING_RUN_POLICY",
    "CHECKPOINT_CLEANUP_MODE",
    "BASELINE_REFERENCE_SECONDS",
    "DMTCP_COORD_PORT",
    "DMTCP_PORT_MIN",
    "DMTCP_PORT_MAX",
    "DMTCP_EXPERIMENT_SIGNAL",
    "COORDINATOR_START_TIMEOUT_SECONDS",
    "CHECKPOINT_FILE_TIMEOUT_SECONDS",
    "POST_CHECKPOINT_STABILIZATION_SECONDS",
    "DMTCP_RESTORE_TIMEOUT_SECONDS",
    "PROGRESS_INTERVAL_SECONDS",
    "RESTORE_PROGRESS_INTERVAL_SECONDS",
    "PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS",
    "PRE_RESTORE_CLEANUP_POLL_SECONDS",
    "PRE_RESTORE_FORCE_KILL_AFTER_SECONDS",
    "PRE_RESTORE_FORCE_KILL_GRACE_SECONDS",
    "PRE_RESTORE_FINAL_GRACE_SECONDS",
    "PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS",
    "RESTORE_BIND_FAILURE_ABORT_SECONDS",
    "RESTORE_MAX_ATTEMPTS",
    "RESTORE_RETRY_FINAL_GRACE_SECONDS",
    "RESTORE_RESERVE_ORIGINAL_TCP_PORTS",
    "RESTORE_PORT_RESERVATION_LOCK_FILE",
    "RESTORE_PORT_RESERVATION_LOCK_TIMEOUT_SECONDS",
    "RESTORE_IP_LOCAL_RESERVED_PORTS_PATH",
    "RESTORE_TUNE_TCP_RECEIVE_WINDOW",
    "RESTORE_TCP_RECEIVE_WINDOW_LOCK_FILE",
    "RESTORE_TCP_RECEIVE_WINDOW_LOCK_TIMEOUT_SECONDS",
    "RESTORE_NET_CORE_RMEM_MAX",
    "RESTORE_NET_IPV4_TCP_RMEM",
    "RESTORE_NET_CORE_RMEM_MAX_PATH",
    "RESTORE_NET_IPV4_TCP_RMEM_PATH",
    "ROOT_PREFIX",
    "BUILD_ROOT",
    "BUILD_JOBS",
    "AUTOCONF_VER",
    "MPICH_VER",
    "DMTCP_REF",
    "DMTCP_REPO",
    "NPB_VERSION",
    "NPB_URL",
    "NPB_TARGET",
    "PYTHON_TEST_ENV_DIR",
    "PYTHON_TEST_BOOTSTRAP",
    "PYTHON_TEST_REQUIREMENTS",
}

REQUIRED_ARTIFACTS = {
    "per_run_results.csv",
    "aggregate_results.csv",
    "run_metadata.txt",
    "pre_run_cleanup.log",
    "run_status.txt",
    "SUCCESS.marker",
    "checkpoint_schedule.tsv",
    "pre_restore_captured_state.json",
    "pre_restore_captured_processes.tsv",
    "pre_restore_captured_sockets.tsv",
    "pre_restore_cleanup_seconds.txt",
    "restore_port_reservation_state.json",
    "restore_tcp_receive_window_state.json",
    "restore_attempts_summary.tsv",
    "dmtcp_restore_seconds.txt",
    "successful_restore_attempt_seconds.txt",
    "checkpoint_restore_workflow_overhead_seconds.txt",
    "total_dmtcp_related_overhead_seconds.txt",
    "residual_dmtcp_runtime_difference_seconds.txt",
}


def repository_files() -> set[str]:
    files: set[str] = set()
    for path in REPO_ROOT.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(REPO_ROOT)
        if any(part in EXCLUDED_PARTS for part in relative.parts):
            continue
        if path.suffix in {".pyc", ".pyo"}:
            continue
        files.add(relative.as_posix())
    return files


def documented_structure_files(readme: str) -> set[str]:
    match = re.search(
        r"<!-- BEGIN REPOSITORY STRUCTURE -->\s*```text\n(.*?)\n```\s*"
        r"<!-- END REPOSITORY STRUCTURE -->",
        readme,
        flags=re.DOTALL,
    )
    if not match:
        raise AssertionError("README repository-structure block or markers are missing")

    stack: list[str] = []
    files: set[str] = set()

    for raw_line in match.group(1).splitlines():
        if not raw_line.strip():
            continue
        indentation = len(raw_line) - len(raw_line.lstrip(" "))
        if indentation % 2:
            raise AssertionError(f"README structure uses invalid indentation: {raw_line!r}")
        level = indentation // 2
        entry = re.split(r"\s{2,}#", raw_line.strip(), maxsplit=1)[0].rstrip()
        if level > len(stack):
            raise AssertionError(f"README structure skips an indentation level: {raw_line!r}")
        stack = stack[:level]
        if entry.endswith("/"):
            stack.append(entry[:-1])
            continue
        files.add("/".join([*stack, entry]))

    return files


def test_readme_matches_repository() -> None:
    readme = README_PATH.read_text(encoding="utf-8")

    actual = repository_files()
    documented = documented_structure_files(readme)
    assert documented == actual, (
        "README repository structure is out of date. "
        f"Missing from README: {sorted(actual - documented)}; "
        f"not present in repository: {sorted(documented - actual)}"
    )

    for variable in sorted(PUBLIC_CONFIGURATION_VARIABLES):
        assert f"`{variable}`" in readme, f"README does not document {variable}"

    for artifact in sorted(REQUIRED_ARTIFACTS):
        assert artifact in readme, f"README does not document artifact {artifact}"

    assert "./scripts/setup_python_test_env.sh" in readme
    assert "./scripts/check_repository.sh" in readme
    assert "./scripts/run_repository_test.sh tests/test_restore_retry.py" in readme
    assert "./scripts/run_repository_test.sh tests/test_run_resume.py" in readme
    assert "mean ± sample SD" in readme

    generic_fix_sections = (
        "### Receive-buffer refill capacity fix",
        "## Restore-port collision protection",
        "## Restore-scoped TCP receive-window tuning",
    )
    for heading in generic_fix_sections:
        start = readme.index(heading)
        next_heading = readme.find("\n## ", start + len(heading))
        if heading.startswith("### "):
            next_h3 = readme.find("\n### ", start + len(heading))
            candidates = [value for value in (next_heading, next_h3) if value != -1]
            next_heading = min(candidates) if candidates else -1
        section = readme[start : next_heading if next_heading != -1 else len(readme)]
        assert re.search(r"\b\d+-rank\b", section) is None, (
            f"{heading} should describe the mechanism generically, not a specific run"
        )
        assert re.search(r"\b(?:BT|CG)\.D\b", section) is None, (
            f"{heading} should not name a specific benchmark incident"
        )
        assert "failure bundle" not in section.lower()

    forbidden = (".idea/", "__pycache__/", ".pyc")
    structure_match = re.search(
        r"<!-- BEGIN REPOSITORY STRUCTURE -->(.*?)"
        r"<!-- END REPOSITORY STRUCTURE -->",
        readme,
        flags=re.DOTALL,
    )
    assert structure_match is not None
    structure_text = structure_match.group(1)
    for item in forbidden:
        assert item not in structure_text, f"README structure includes generated item {item}"


    handoff_phrases = (
        "delivered",
        "delivery",
        "handoff",
        "uploaded",
        "downloadable",
    )
    readme_lower = readme.lower()
    for phrase in handoff_phrases:
        assert phrase not in readme_lower, (
            f"README contains handoff-oriented wording: {phrase}"
        )


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-p", "no:cacheprovider"]))
