#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=experiment_config.sh
source "${SCRIPT_DIR}/experiment_config.sh"

for helper in \
  run_one.sh build_npb_bt_cg_d.sh install_npb_mpi.sh \
  verify_single_node_environment.sh kill_dmtcp_processes.sh \
  adaptive_pre_restore_cleanup.py; do
  chmod +x "${SCRIPT_DIR}/${helper}"
done

for helper in \
  test_adaptive_pre_restore_cleanup.py; do
  chmod +x "${TEST_DIR}/${helper}"
done

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

is_nonnegative_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_positive_number() {
  is_nonnegative_number "$1" || return 1
  python3 - "$1" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) > 0 else 1)
PY
}

if [ ! -f "${ENV_FILE}" ]; then
  fail "DMTCP/MPICH environment helper not found: ${ENV_FILE}"
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

if ! verify_single_node_stack; then
  fail "the exact working single-node DMTCP/MPICH stack is not active."
fi

case "${RUN_BASELINE}" in
  true|false)
    ;;
  *)
    fail "RUN_BASELINE must be true or false."
    ;;
esac

case "${CHECKPOINT_CLEANUP_MODE}" in
  delete-checkpoints|keep-checkpoints)
    ;;
  *)
    fail "CHECKPOINT_CLEANUP_MODE must be delete-checkpoints or keep-checkpoints."
    ;;
esac

case "${EXISTING_RUN_POLICY}" in
  replace|skip|error)
    ;;
  *)
    fail "EXISTING_RUN_POLICY must be replace, skip, or error."
    ;;
esac

if [ "${COORDINATOR_LIFECYCLE}" != "fresh" ]; then
  fail "this package intentionally uses the successful fresh-coordinator workflow."
fi

for positive_setting in \
  PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS \
  PRE_RESTORE_CLEANUP_POLL_SECONDS \
  PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS \
  RESTORE_BIND_FAILURE_ABORT_SECONDS; do
  is_positive_number "${!positive_setting}" \
    || fail "${positive_setting} must be a positive number; received '${!positive_setting}'."
done

for nonnegative_setting in \
  PRE_RESTORE_FORCE_KILL_AFTER_SECONDS \
  PRE_RESTORE_FORCE_KILL_GRACE_SECONDS \
  PRE_RESTORE_FINAL_GRACE_SECONDS; do
  is_nonnegative_number "${!nonnegative_setting}" \
    || fail "${nonnegative_setting} must be a nonnegative number; received '${!nonnegative_setting}'."
done

if [ "${#BENCHMARKS[@]}" -eq 0 ] || \
   [ "${#MPI_RANKS[@]}" -eq 0 ] || \
   [ "${#CHECKPOINT_PERCENTAGES[@]}" -eq 0 ]; then
  fail "benchmark, rank, and checkpoint-percentage lists must not be empty."
fi

[[ "${BASELINE_REPETITIONS}" =~ ^[1-9][0-9]*$ ]] \
  || fail "BASELINE_REPETITIONS must be a positive integer; received '${BASELINE_REPETITIONS}'."

[[ "${CR_REPETITIONS}" =~ ^[1-9][0-9]*$ ]] \
  || fail "CR_REPETITIONS must be a positive integer; received '${CR_REPETITIONS}'."

mkdir -p "${RESULTS_ROOT}"
RESULTS_ROOT="$(cd -- "${RESULTS_ROOT}" && pwd)"

for benchmark in "${BENCHMARKS[@]}"; do
  case "${benchmark}" in
    bt|cg)
      ;;
    *)
      fail "unsupported benchmark '${benchmark}'; use bt and/or cg."
      ;;
  esac

  if [ ! -x "${BINARY_ROOT}/${benchmark}.${NPB_CLASS}.x" ]; then
    fail "missing ${BINARY_ROOT}/${benchmark}.${NPB_CLASS}.x; run build_npb_bt_cg_d.sh first."
  fi

  MPI_LINKAGE="$(ldd "${BINARY_ROOT}/${benchmark}.${NPB_CLASS}.x" 2>/dev/null || true)"
  if ! printf "%s\n" "${MPI_LINKAGE}" | grep -F "${MPICH_HOME}/" >/dev/null && \
     ! printf "%s\n" "${MPI_LINKAGE}" | grep -F "$(readlink -f "${MPICH_HOME}")/" >/dev/null; then
    fail "${BINARY_ROOT}/${benchmark}.${NPB_CLASS}.x is not linked to the active reproducible MPICH; rebuild it with build_npb_bt_cg_d.sh."
  fi
done

for percentage in "${CHECKPOINT_PERCENTAGES[@]}"; do
  if ! [[ "${percentage}" =~ ^[0-9]+$ ]] || \
     [ "${percentage}" -le 0 ] || \
     [ "${percentage}" -ge 100 ]; then
    fail "checkpoint percentages must be integers between 1 and 99; received '${percentage}'."
  fi
done

compute_baseline_mean() {
  local benchmark="$1"
  local np="$2"
  local repetition_count="$3"

  python3 - "${RESULTS_ROOT}" "${benchmark}" "${NPB_CLASS}" "${np}" "${repetition_count}" <<'PY'
from pathlib import Path
import statistics
import sys

results_root = Path(sys.argv[1])
benchmark = sys.argv[2]
npb_class = sys.argv[3]
np = int(sys.argv[4])
repetition_count = int(sys.argv[5])

values = []
for repetition in range(1, repetition_count + 1):
    run_dir = results_root / f"{benchmark}{npb_class}_np{np}_baseline_rep{repetition}"
    status_file = run_dir / "run_status.txt"
    total_file = run_dir / "total_seconds.txt"

    if not status_file.exists() or status_file.read_text().strip() != "SUCCESS":
        raise SystemExit(f"incomplete baseline run: {run_dir}")
    if not total_file.exists():
        raise SystemExit(f"missing baseline timing: {total_file}")

    values.append(float(total_file.read_text().strip()))

print(f"{statistics.mean(values):.9f}")
PY
}

checkpoint_delay() {
  local baseline_mean="$1"
  local percentage="$2"

  python3 - "${baseline_mean}" "${percentage}" <<'PY'
import sys

baseline = float(sys.argv[1])
percentage = int(sys.argv[2])
print(f"{baseline * percentage / 100.0:.9f}")
PY
}

echo "============================================================"
echo "NPB/DMTCP checkpoint/restore experiment suite"
echo "Benchmarks:             ${BENCHMARKS[*]}"
echo "NPB class:              ${NPB_CLASS}"
echo "MPI ranks:              ${MPI_RANKS[*]}"
echo "Baseline repetitions:   ${BASELINE_REPETITIONS} (IDs 1-${BASELINE_REPETITIONS})"
echo "CR repetitions:         ${CR_REPETITIONS} per percentage (IDs 1-${CR_REPETITIONS})"
echo "Checkpoint percentages: ${CHECKPOINT_PERCENTAGES[*]}"
echo "Run baselines:          ${RUN_BASELINE}"
echo "Existing-run policy:    ${EXISTING_RUN_POLICY}"
echo "Checkpoint cleanup:     ${CHECKPOINT_CLEANUP_MODE}"
echo "Coordinator lifecycle:  ${COORDINATOR_LIFECYCLE} (--exit-on-last)"
echo "Coordinator port range: ${DMTCP_PORT_MIN}-${DMTCP_PORT_MAX}"
echo "Pre-restore cleanup:     timeout=${PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS}s, poll=${PRE_RESTORE_CLEANUP_POLL_SECONDS}s"
echo "Cleanup escalation:      TERM after ${PRE_RESTORE_FORCE_KILL_AFTER_SECONDS}s, KILL ${PRE_RESTORE_FORCE_KILL_GRACE_SECONDS}s later"
echo "Final verified grace:    ${PRE_RESTORE_FINAL_GRACE_SECONDS}s"
echo "Bind-failure abort:      ${RESTORE_BIND_FAILURE_ABORT_SECONDS}s persistent"
echo "DMTCP commit:           ${DMTCP_COMMIT}"
echo "DMTCP restore backlog:  ${DMTCP_RESTORE_LISTEN_BACKLOG} (kernel somaxconn $(cat /proc/sys/net/core/somaxconn))"
echo "MPICH:                  ${MPICH_VERSION} (${MPICH_DEVICE}, libudev ${MPICH_HWLOC_LIBUDEV})"
echo "DMTCP signal:           ${DMTCP_EXPERIMENT_SIGNAL}"
echo "Output root:            ${OUTPUT_ROOT}"
echo "Binaries:               ${BINARY_ROOT}"
echo "Results/checkpoints:    ${RESULTS_ROOT}"
echo "============================================================"

for benchmark in "${BENCHMARKS[@]}"; do
  for np in "${MPI_RANKS[@]}"; do
    echo
    echo "============================================================"
    echo "${benchmark^^}.${NPB_CLASS}, MPI ranks=${np}"
    echo "============================================================"

    if [ "${RUN_BASELINE}" = "true" ]; then
      echo
      echo "Running baseline repetitions first..."

      for (( repetition=1; repetition<=BASELINE_REPETITIONS; repetition++ )); do
        "${SCRIPT_DIR}/run_one.sh" \
          "${benchmark}" "${np}" baseline "${repetition}" \
          "${CHECKPOINT_CLEANUP_MODE}"
      done
    else
      echo
      echo "Reusing existing baseline repetitions..."
    fi

    if ! BASELINE_MEAN="$(compute_baseline_mean "${benchmark}" "${np}" "${BASELINE_REPETITIONS}")"; then
      fail "could not compute a complete baseline mean for ${benchmark^^}.${NPB_CLASS}, ranks=${np}."
    fi

    REFERENCE_FILE="${RESULTS_ROOT}/${benchmark}${NPB_CLASS}_np${np}_baseline_reference_seconds.txt"
    echo "${BASELINE_MEAN}" > "${REFERENCE_FILE}"

    SCHEDULE_FILE="${RESULTS_ROOT}/${benchmark}${NPB_CLASS}_np${np}_checkpoint_schedule.tsv"
    {
      echo -e "benchmark\tclass\tmpi_ranks\tbaseline_mean_seconds\tcheckpoint_percentage\tcheckpoint_target_seconds"
      for percentage in "${CHECKPOINT_PERCENTAGES[@]}"; do
        target="$(checkpoint_delay "${BASELINE_MEAN}" "${percentage}")"
        echo -e "${benchmark}\t${NPB_CLASS}\t${np}\t${BASELINE_MEAN}\t${percentage}\t${target}"
      done
    } > "${SCHEDULE_FILE}"

    echo
    echo "Baseline mean: ${BASELINE_MEAN} seconds"
    echo "Checkpoint schedule:"
    while IFS=$'\t' read -r _benchmark _class _np _baseline percentage target; do
      if [ "${percentage}" != "checkpoint_percentage" ]; then
        echo "  ${percentage}% -> ${target} seconds after launch"
      fi
    done < "${SCHEDULE_FILE}"

    for percentage in "${CHECKPOINT_PERCENTAGES[@]}"; do
      TARGET_SECONDS="$(checkpoint_delay "${BASELINE_MEAN}" "${percentage}")"

      echo
      echo "------------------------------------------------------------"
      echo "Running CR at ${percentage}% (${TARGET_SECONDS}s), ${CR_REPETITIONS} configured repetitions"
      echo "------------------------------------------------------------"

      for (( repetition=1; repetition<=CR_REPETITIONS; repetition++ )); do
        BASELINE_REFERENCE_SECONDS="${BASELINE_MEAN}" \
          "${SCRIPT_DIR}/run_one.sh" \
            "${benchmark}" "${np}" cr percent "${percentage}" "${repetition}" \
            "${CHECKPOINT_CLEANUP_MODE}"

        CR_DIR="${RESULTS_ROOT}/${benchmark}${NPB_CLASS}_np${np}_cr_p${percentage}_rep${repetition}"
        echo "${BASELINE_MEAN}" > "${CR_DIR}/baseline_reference_seconds.txt"
      done
    done
  done
done

echo
echo "============================================================"
echo "Summarizing completed results"
echo "============================================================"

python3 "${SCRIPT_DIR}/summarize_results.py" --results-root "${RESULTS_ROOT}"
