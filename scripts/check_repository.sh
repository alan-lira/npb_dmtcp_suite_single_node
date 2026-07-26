#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(cd -- "${REPO_ROOT}/tests" && pwd)"

failed=0

for script in "${SCRIPT_DIR}"/*.sh; do
  if bash -n "${script}"; then
    printf '[OK] bash syntax: %s\n' "${script#${REPO_ROOT}/}"
  else
    failed=1
  fi
done

# bash -n does not evaluate parameter expansions, so source the shared
# configuration once to catch runtime errors before a build or experiment.
if (
  set -euo pipefail
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/experiment_config.sh"
  : \
    "${REPO_ROOT}" "${OUTPUT_ROOT}" "${BINARY_ROOT}" "${RESULTS_ROOT}" \
    "${PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS}" \
    "${PRE_RESTORE_CLEANUP_POLL_SECONDS}" \
    "${PRE_RESTORE_FORCE_KILL_AFTER_SECONDS}" \
    "${PRE_RESTORE_FORCE_KILL_GRACE_SECONDS}" \
    "${PRE_RESTORE_FINAL_GRACE_SECONDS}" \
    "${PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS}" \
    "${RESTORE_BIND_FAILURE_ABORT_SECONDS}"
); then
  printf '[OK] runtime load: scripts/experiment_config.sh\n'
else
  printf '[ERROR] runtime load failed: scripts/experiment_config.sh\n' >&2
  failed=1
fi

for script in "${SCRIPT_DIR}"/*.py; do
  if python3 -m py_compile "${script}"; then
    printf '[OK] Python syntax: %s\n' "${script#${REPO_ROOT}/}"
  else
    failed=1
  fi
done

for executable in "${SCRIPT_DIR}"/*.sh "${SCRIPT_DIR}"/*.py; do
  if [ -x "${executable}" ]; then
    printf '[OK] executable: %s\n' "${executable#${REPO_ROOT}/}"
  else
    printf '[ERROR] not executable: %s\n' "${executable#${REPO_ROOT}/}" >&2
    failed=1
  fi
done

stale_script_pattern='00_build_npb|01_run_all|install_dmtcp_mpich_working_env|old_run_one\.sh'
if grep -RInE "${stale_script_pattern}" \
    "${REPO_ROOT}/README.md" "${SCRIPT_DIR}" \
    --exclude='check_repository.sh'; then
  printf '[ERROR] stale script-name references found.\n' >&2
  failed=1
else
  printf '[OK] no stale script-name references\n'
fi

obsolete_cleanup_pattern='SOCKET_CLEANUP_SLEEP_SECONDS|[Ww]ait(ing)? [0-9]+ seconds for operating-system socket cleanup|socket-cleanup delay completed|fixed socket-cleanup delay|blind socket-cleanup'
if grep -RInE "${obsolete_cleanup_pattern}" \
    "${REPO_ROOT}/README.md" "${SCRIPT_DIR}" \
    --exclude='check_repository.sh'; then
  printf '[ERROR] obsolete fixed socket-cleanup references found.\n' >&2
  failed=1
else
  printf '[OK] no obsolete fixed socket-cleanup references\n'
fi

required_settings=(
  PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS
  PRE_RESTORE_CLEANUP_POLL_SECONDS
  PRE_RESTORE_FORCE_KILL_AFTER_SECONDS
  PRE_RESTORE_FORCE_KILL_GRACE_SECONDS
  PRE_RESTORE_FINAL_GRACE_SECONDS
  PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS
  RESTORE_BIND_FAILURE_ABORT_SECONDS
)
for setting in "${required_settings[@]}"; do
  if grep -Rqs "${setting}" \
      "${SCRIPT_DIR}/experiment_config.sh" \
      "${SCRIPT_DIR}/run_one.sh" \
      "${REPO_ROOT}/README.md"; then
    printf '[OK] adaptive setting documented and used: %s\n' "${setting}"
  else
    printf '[ERROR] adaptive setting missing from config, runner, or README: %s\n' "${setting}" >&2
    failed=1
  fi
done

if "${TEST_DIR}/test_adaptive_pre_restore_cleanup.py"; then
  printf '[OK] controlled adaptive process/socket cleanup tests\n'
else
  printf '[ERROR] controlled adaptive process/socket cleanup tests failed\n' >&2
  failed=1
fi

if [ -d "${REPO_ROOT}/.idea" ]; then
  printf '[ERROR] .idea/ should not be included in the delivered repository.\n' >&2
  failed=1
else
  printf '[OK] no .idea directory\n'
fi

exit "${failed}"
