#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${REPO_ROOT}/tests"

failed=0

report_error() {
  printf '[ERROR] %s\n' "$*" >&2
  failed=1
}

for script in "${SCRIPT_DIR}"/*.sh; do
  if bash -n "${script}"; then
    printf '[OK] Bash syntax: %s\n' "${script#${REPO_ROOT}/}"
  else
    failed=1
  fi
done

if (
  set -euo pipefail
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/experiment_config.sh"
  : \
    "${REPO_ROOT}" "${OUTPUT_ROOT}" "${BINARY_ROOT}" "${RESULTS_ROOT}" \
    "${EXISTING_RUN_POLICY}" \
    "${PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS}" \
    "${PRE_RESTORE_CLEANUP_POLL_SECONDS}" \
    "${PRE_RESTORE_FORCE_KILL_AFTER_SECONDS}" \
    "${PRE_RESTORE_FORCE_KILL_GRACE_SECONDS}" \
    "${PRE_RESTORE_FINAL_GRACE_SECONDS}" \
    "${PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS}" \
    "${RESTORE_BIND_FAILURE_ABORT_SECONDS}" \
    "${RESTORE_MAX_ATTEMPTS}" \
    "${RESTORE_RETRY_FINAL_GRACE_SECONDS}" \
    "${RESTORE_RESERVE_ORIGINAL_TCP_PORTS}" \
    "${RESTORE_PORT_RESERVATION_LOCK_FILE}" \
    "${RESTORE_PORT_RESERVATION_LOCK_TIMEOUT_SECONDS}" \
    "${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH}" \
    "${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}" \
    "${WORKING_DMTCP_RESTORE_LISTENER_PATHS}" \
    "${WORKING_DMTCP_DUPLEX_PATCH_SHA256}"
); then
  printf '[OK] Runtime load: scripts/experiment_config.sh\n'
else
  report_error 'runtime load failed: scripts/experiment_config.sh'
fi

for script in "${SCRIPT_DIR}"/*.py "${TEST_DIR}"/*.py; do
  if python3 - "${script}" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY
  then
    printf '[OK] Python syntax: %s\n' "${script#${REPO_ROOT}/}"
  else
    failed=1
  fi
done

for executable in \
  "${SCRIPT_DIR}"/*.sh \
  "${SCRIPT_DIR}"/*.py \
  "${TEST_DIR}"/*.py; do
  if [ -x "${executable}" ]; then
    printf '[OK] Executable: %s\n' "${executable#${REPO_ROOT}/}"
  else
    report_error "not executable: ${executable#${REPO_ROOT}/}"
  fi
done

stale_script_pattern='00_build_npb|01_run_all|install_dmtcp_mpich_working_env|old_run_one\.sh'
if grep -RInE "${stale_script_pattern}" \
    "${REPO_ROOT}/README.md" "${SCRIPT_DIR}" "${TEST_DIR}" \
    --exclude='check_repository.sh'; then
  report_error 'stale script-name references found'
else
  printf '[OK] No stale script-name references\n'
fi

obsolete_cleanup_pattern='SOCKET_CLEANUP_SLEEP_SECONDS|[Ww]ait(ing)? [0-9]+ seconds for operating-system socket cleanup|socket-cleanup delay completed|fixed socket-cleanup delay|blind socket-cleanup'
if grep -RInE "${obsolete_cleanup_pattern}" \
    "${REPO_ROOT}/README.md" "${SCRIPT_DIR}" "${TEST_DIR}" \
    --exclude='check_repository.sh'; then
  report_error 'obsolete fixed socket-cleanup references found'
else
  printf '[OK] No obsolete fixed socket-cleanup references\n'
fi

obsolete_artifact_pattern='additional_overhead_(seconds|percent)\.txt|checkpoint_overhead_seconds\.txt|checkpoint_restore_procedure_overhead_seconds\.txt|residual_dmtcp_runtime_overhead_seconds\.txt|socket_cleanup_sleep_seconds\.txt|total_wall_seconds\.txt|(^|[^[:alnum:]_])restore_seconds\.txt'
if grep -RInE "${obsolete_artifact_pattern}" \
    "${REPO_ROOT}/README.md" "${SCRIPT_DIR}" \
    --exclude='check_repository.sh'; then
  report_error 'obsolete output-artifact aliases found'
else
  printf '[OK] Only current output-artifact names are used\n'
fi

obsolete_compatibility_pattern='legacy_baseline_target|baseline_t\*_rep|replace\|skip\|error|Backward-compatible|backward-compatible'
if grep -RInE "${obsolete_compatibility_pattern}" \
    "${REPO_ROOT}/README.md" "${SCRIPT_DIR}" \
    --exclude='check_repository.sh'; then
  report_error 'obsolete compatibility logic or documentation found'
else
  printf '[OK] No obsolete compatibility logic or documentation\n'
fi

required_settings=(
  PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS
  PRE_RESTORE_CLEANUP_POLL_SECONDS
  PRE_RESTORE_FORCE_KILL_AFTER_SECONDS
  PRE_RESTORE_FORCE_KILL_GRACE_SECONDS
  PRE_RESTORE_FINAL_GRACE_SECONDS
  PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS
  RESTORE_BIND_FAILURE_ABORT_SECONDS
  RESTORE_MAX_ATTEMPTS
  RESTORE_RETRY_FINAL_GRACE_SECONDS
  RESTORE_RESERVE_ORIGINAL_TCP_PORTS
  RESTORE_PORT_RESERVATION_LOCK_FILE
  RESTORE_PORT_RESERVATION_LOCK_TIMEOUT_SECONDS
  RESTORE_IP_LOCAL_RESERVED_PORTS_PATH
)
for setting in "${required_settings[@]}"; do
  missing=0
  for file in \
    "${SCRIPT_DIR}/experiment_config.sh" \
    "${SCRIPT_DIR}/run_one.sh" \
    "${REPO_ROOT}/README.md"; do
    grep -q "${setting}" "${file}" || missing=1
  done
  if [ "${missing}" -eq 0 ]; then
    printf '[OK] Adaptive setting documented and used: %s\n' "${setting}"
  else
    report_error "adaptive setting missing from config, runner, or README: ${setting}"
  fi
done

for backlog_file in \
  "${SCRIPT_DIR}/install_dmtcp_mpich_env.sh" \
  "${SCRIPT_DIR}/experiment_config.sh" \
  "${SCRIPT_DIR}/verify_single_node_environment.sh" \
  "${SCRIPT_DIR}/run_all.sh" \
  "${SCRIPT_DIR}/run_one.sh" \
  "${REPO_ROOT}/README.md"; do
  if grep -Eq 'DMTCP_RESTORE_LISTEN_BACKLOG|restore-listener backlog|restore listener backlog|DMTCP restore backlog' \
      "${backlog_file}"; then
    printf '[OK] DMTCP restore-backlog fix integrated: %s\n' \
      "${backlog_file#${REPO_ROOT}/}"
  else
    report_error "DMTCP restore-backlog integration missing: ${backlog_file#${REPO_ROOT}/}"
  fi
done

if grep -Fq 'BUILD_JOBS="${BUILD_JOBS:-8}"' \
    "${SCRIPT_DIR}/install_dmtcp_mpich_env.sh" && \
   grep -Fq 'make -j"${BUILD_JOBS}"' \
    "${SCRIPT_DIR}/install_dmtcp_mpich_env.sh" && \
   ! grep -Fq 'make -j"$(nproc)"' \
    "${SCRIPT_DIR}/install_dmtcp_mpich_env.sh"; then
  printf '[OK] Bounded installer build parallelism\n'
else
  report_error 'bounded BUILD_JOBS integration is incomplete'
fi

DMTCP_PATCH_DIR="${REPO_ROOT}/patches/dmtcp-6896e12276a9fe449edb0cf206203ce01b19efe6"
BACKLOG_PATCH="${DMTCP_PATCH_DIR}/connectionrewirer-backlog-1024.exact.patch"
DUPLEX_PATCH="${DMTCP_PATCH_DIR}/kernelbufferdrainer-duplex-refill.patch"
OLD_DUPLEX_OVERRIDE="${DMTCP_PATCH_DIR}/kernelbufferdrainer.cpp"
EXPECTED_BACKLOG_PATCH_SHA256="72bc6bc3d338a78c9e1ebe89692f12c544e92ad2862be58b8aca942702a981a1"
EXPECTED_DUPLEX_PATCH_SHA256="93a2edf137e6214410b436ecbed1ae0d6cf3056e2bb6325910d52e50e3df28a2"

backlog_pairs_ok=1
grep -Fxq 'FROM=jalib::JServerSocket restoreSocket(sockAddr, 0);' "${BACKLOG_PATCH}" 2>/dev/null \
  || backlog_pairs_ok=0
grep -Fxq 'TO=jalib::JServerSocket restoreSocket(sockAddr, 0, 1024);' "${BACKLOG_PATCH}" 2>/dev/null \
  || backlog_pairs_ok=0
for fd_name in ip6fd udsfd udsseqfd; do
  grep -Fxq "FROM=_real_listen(${fd_name}, 32)" "${BACKLOG_PATCH}" 2>/dev/null \
    || backlog_pairs_ok=0
  grep -Fxq "TO=_real_listen(${fd_name}, 1024)" "${BACKLOG_PATCH}" 2>/dev/null \
    || backlog_pairs_ok=0
done

if [ -f "${BACKLOG_PATCH}" ] && \
   [ -f "${DUPLEX_PATCH}" ] && \
   [ ! -e "${OLD_DUPLEX_OVERRIDE}" ] && \
   [ "$(sha256sum "${BACKLOG_PATCH}" | awk '{print $1}')" = \
     "${EXPECTED_BACKLOG_PATCH_SHA256}" ] && \
   [ "$(sha256sum "${DUPLEX_PATCH}" | awk '{print $1}')" = \
     "${EXPECTED_DUPLEX_PATCH_SHA256}" ] && \
   [ "${backlog_pairs_ok}" -eq 1 ] && \
   grep -Fq 'DMTCP_BACKLOG_PATCH_FILE=' \
     "${SCRIPT_DIR}/install_dmtcp_mpich_env.sh" && \
   grep -Fq 'DMTCP_DUPLEX_REFILL_PATCH_FILE=' \
     "${SCRIPT_DIR}/install_dmtcp_mpich_env.sh" && \
   grep -Fq 'patch --batch --forward --fuzz=0 -p1' \
     "${SCRIPT_DIR}/install_dmtcp_mpich_env.sh" && \
   grep -Fq '+#include <poll.h>' "${DUPLEX_PATCH}" && \
   grep -Fq 'stream-refill payload send failed' "${DUPLEX_PATCH}" && \
   grep -Fq 'stream-refill receive buffer is too small' "${DUPLEX_PATCH}" && \
   grep -Fq 'SO_RCVBUFFORCE' "${DUPLEX_PATCH}" && \
   grep -Fq 'DMTCP_REFILL_RECEIVE_CAPACITY_PATCH_ACTIVE=1' \
     "${SCRIPT_DIR}/experiment_config.sh"; then
  printf '[OK] Version-specific DMTCP patch bundle integration\n'
else
  report_error 'version-specific DMTCP patch bundle integration is incomplete'
fi

if [ -x "${SCRIPT_DIR}/restore_port_reservation.py" ] && \
   grep -Fq 'reserve_restore_ports' "${SCRIPT_DIR}/run_one.sh" && \
   grep -Fq 'release_restore_ports' "${SCRIPT_DIR}/run_one.sh" && \
   grep -Fq 'ip_local_reserved_ports' "${SCRIPT_DIR}/restore_port_reservation.py" && \
   grep -Fq 'flock -w "${RESTORE_PORT_RESERVATION_LOCK_TIMEOUT_SECONDS}"' \
     "${SCRIPT_DIR}/run_one.sh" && \
   grep -Fq 'Restore-port collision protection' "${REPO_ROOT}/README.md"; then
  printf '[OK] Transactional restore-port reservation integration\n'
else
  report_error 'transactional restore-port reservation integration is incomplete'
fi

if grep -Fq 'copy_restore_attempt_to_canonical_logs "${SUCCESSFUL_ATTEMPT_DIR}"' \
    "${SCRIPT_DIR}/run_one.sh"; then
  printf '[OK] Final successful-attempt log refresh integration\n'
else
  report_error 'final successful-attempt logs are not refreshed after application exit'
fi

if grep -Fq 'RESTORE_MAX_ATTEMPTS="${RESTORE_MAX_ATTEMPTS:-3}"' \
    "${SCRIPT_DIR}/experiment_config.sh" && \
   grep -Fq 'cleanup_failed_restore_attempt' \
    "${SCRIPT_DIR}/run_one.sh" && \
   grep -Fq 'restore_attempts_summary.tsv' \
    "${SCRIPT_DIR}/run_one.sh" && \
   grep -Fq 'Automatic restore retries' "${REPO_ROOT}/README.md"; then
  printf '[OK] Bounded same-checkpoint restore retry integration\n'
else
  report_error 'bounded restore retry integration is incomplete'
fi

if grep -Fq 'EXISTING_RUN_POLICY="${EXISTING_RUN_POLICY:-resume}"' \
    "${SCRIPT_DIR}/experiment_config.sh" && \
   grep -Fq 'SUCCESS.marker' "${SCRIPT_DIR}/run_one.sh" && \
   grep -Fq 'SUCCESS.marker' "${SCRIPT_DIR}/run_all.sh" && \
   grep -Fq 'SUCCESS.marker' "${SCRIPT_DIR}/summarize_results.py" && \
   grep -Fq 'SUCCESS.marker' "${REPO_ROOT}/README.md"; then
  printf '[OK] Success-marker and resume integration\n'
else
  report_error 'success-marker or resume integration is incomplete'
fi

if grep -Fq '"${SCRIPT_DIR}/kill_dmtcp_processes.sh" > pre_run_cleanup.log 2>&1' \
    "${SCRIPT_DIR}/run_one.sh" && \
   grep -Fq 'pre_run_cleanup.log' "${REPO_ROOT}/README.md"; then
  printf '[OK] Default pre-run process cleanup integration\n'
else
  report_error 'default pre-run process cleanup integration is incomplete'
fi

for test_script in \
  test_summarize_results.py \
  test_repository_contract.py \
  test_dmtcp_patch_application.py \
  test_refill_receive_capacity.py \
  test_restore_port_reservation.py \
  test_adaptive_pre_restore_cleanup.py; do
  printf '[RUN] Test: tests/%s\n' "${test_script}"
  test_log="$(mktemp)"
  if "${TEST_DIR}/${test_script}" > "${test_log}" 2>&1; then
    cat "${test_log}"
    printf '[OK] Test passed: tests/%s\n' "${test_script}"
  else
    cat "${test_log}" >&2
    report_error "test failed: tests/${test_script}"
  fi
  rm -f -- "${test_log}"
done

printf '[INFO] Environment-sensitive integration tests are run separately: tests/test_restore_retry.py and tests/test_run_resume.py\n'

if [ -d "${REPO_ROOT}/.idea" ]; then
  report_error '.idea/ should not be included in the delivered repository'
else
  printf '[OK] No .idea directory\n'
fi

exit "${failed}"
