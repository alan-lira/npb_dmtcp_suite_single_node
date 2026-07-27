#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=experiment_config.sh
source "${SCRIPT_DIR}/experiment_config.sh"

ADAPTIVE_CLEANUP_HELPER="${SCRIPT_DIR}/adaptive_pre_restore_cleanup.py"
RESTORE_PORT_RESERVATION_HELPER="${SCRIPT_DIR}/restore_port_reservation.py"

usage() {
  cat <<USAGE
Usage:
  $0 <bt|cg> <mpi-ranks> baseline <rep> [delete-checkpoints|keep-checkpoints]
  $0 <bt|cg> <mpi-ranks> cr percent <checkpoint-percent> <rep> [delete-checkpoints|keep-checkpoints]
  $0 <bt|cg> <mpi-ranks> cr delay <checkpoint-delay-seconds> <rep> [delete-checkpoints|keep-checkpoints]

Percentage mode requires either successful matching baseline runs under
RESULTS_ROOT or an explicit BASELINE_REFERENCE_SECONDS value.

Examples:
  $0 bt 25 baseline 1 keep-checkpoints
  $0 bt 25 cr percent 10 1 keep-checkpoints
  BASELINE_REFERENCE_SECONDS=1373.779475573 $0 bt 25 cr percent 10 1 keep-checkpoints
  $0 bt 25 cr delay 60 1 keep-checkpoints
  $0 cg 8 cr delay 60 1 keep-checkpoints
USAGE
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

phase() {
  local name="$1"
  shift
  printf '[%s] %s\n' "${name}" "$*"
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
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

resolve_percentage_baseline() {
  if [[ "${BASELINE_REFERENCE_SECONDS:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    python3 - "${BASELINE_REFERENCE_SECONDS}" <<'PY'
import sys
value = float(sys.argv[1])
if value <= 0:
    raise SystemExit(1)
print(f'{value:.9f}')
PY
    return
  fi

  python3 - "${RESULTS_ROOT}" "${BENCHMARK}" "${NPB_CLASS}" "${NP}" <<'PY'
from pathlib import Path
import statistics
import sys

root = Path(sys.argv[1])
benchmark, npb_class, np = sys.argv[2], sys.argv[3], int(sys.argv[4])
values = []
for run_dir in root.glob(f'{benchmark}{npb_class}_np{np}_baseline_rep*'):
    if not run_dir.is_dir():
        continue
    success_marker = run_dir / 'SUCCESS.marker'
    total = run_dir / 'total_seconds.txt'
    if success_marker.is_file() and total.is_file():
        value = float(total.read_text().strip())
        if value > 0:
            values.append(value)
if not values:
    raise SystemExit(1)
print(f'{statistics.mean(values):.9f}')
PY
}

# ---------------------------------------------------------------------------
# Checkpoint targeting modes are mutually exclusive:
#   percent -> derive the delay from a baseline duration;
#   delay   -> use the supplied absolute delay directly.
# ---------------------------------------------------------------------------
CHECKPOINT_MODE="none"
CHECKPOINT_PERCENT="N/A"
CHECKPOINT_BASELINE_SECONDS="N/A"
CHECKPOINT_DELAY_SECONDS="0"
CHECKPOINT_LABEL=""
CHECKPOINT_CLEANUP_MODE_ARG=""

if [ "$#" -lt 4 ] || ! [[ "${1,,}" =~ ^(bt|cg)$ ]]; then
  usage
  exit 1
fi

BENCHMARK="${1,,}"
NP="$2"
SCENARIO="${3,,}"

case "${SCENARIO}" in
  baseline)
    if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
      usage
      exit 1
    fi
    REP="$4"
    CHECKPOINT_CLEANUP_MODE_ARG="${5:-}"
    ;;
  cr)
    if [ "$#" -lt 6 ] || [ "$#" -gt 7 ]; then
      usage
      exit 1
    fi
    CHECKPOINT_MODE="${4,,}"
    CHECKPOINT_TARGET_VALUE="$5"
    REP="$6"
    CHECKPOINT_CLEANUP_MODE_ARG="${7:-}"
    ;;
  *)
    fail "scenario must be baseline or cr; received '${SCENARIO}'."
    ;;
esac

if [ -n "${CHECKPOINT_CLEANUP_MODE_ARG}" ]; then
  CHECKPOINT_CLEANUP_MODE="${CHECKPOINT_CLEANUP_MODE_ARG}"
fi

is_positive_integer "${NP}" || fail "MPI rank count must be a positive integer."
is_positive_integer "${REP}" || fail "repetition number must be a positive integer."

case "${CHECKPOINT_CLEANUP_MODE}" in
  delete-checkpoints|keep-checkpoints) ;;
  *) fail "CHECKPOINT_CLEANUP_MODE must be delete-checkpoints or keep-checkpoints." ;;
esac

case "${EXISTING_RUN_POLICY}" in
  resume|replace|error) ;;
  *) fail "EXISTING_RUN_POLICY must be resume, replace, or error." ;;
esac

for positive_setting in \
  PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS \
  PRE_RESTORE_CLEANUP_POLL_SECONDS \
  PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS \
  RESTORE_BIND_FAILURE_ABORT_SECONDS \
  RESTORE_PORT_RESERVATION_LOCK_TIMEOUT_SECONDS; do
  is_positive_number "${!positive_setting}" \
    || fail "${positive_setting} must be a positive number; received '${!positive_setting}'."
done

for nonnegative_setting in \
  PRE_RESTORE_FORCE_KILL_AFTER_SECONDS \
  PRE_RESTORE_FORCE_KILL_GRACE_SECONDS \
  PRE_RESTORE_FINAL_GRACE_SECONDS \
  RESTORE_RETRY_FINAL_GRACE_SECONDS; do
  is_nonnegative_number "${!nonnegative_setting}" \
    || fail "${nonnegative_setting} must be a nonnegative number; received '${!nonnegative_setting}'."
done

is_positive_integer "${RESTORE_MAX_ATTEMPTS}" \
  || fail "RESTORE_MAX_ATTEMPTS must be a positive integer; received '${RESTORE_MAX_ATTEMPTS}'."

case "${RESTORE_RESERVE_ORIGINAL_TCP_PORTS}" in
  true|false) ;;
  *) fail "RESTORE_RESERVE_ORIGINAL_TCP_PORTS must be true or false." ;;
esac

[ -x "${ADAPTIVE_CLEANUP_HELPER}" ] \
  || fail "adaptive cleanup helper is missing or not executable: ${ADAPTIVE_CLEANUP_HELPER}"
[ -x "${RESTORE_PORT_RESERVATION_HELPER}" ] \
  || fail "restore port-reservation helper is missing or not executable: ${RESTORE_PORT_RESERVATION_HELPER}"
python3 - <<'PY' \
  || fail "Python/Linux pidfd support is required for PID-reuse-safe cleanup escalation."
import os
import signal
raise SystemExit(0 if hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal") else 1)
PY

if [ "${SCENARIO}" = "cr" ]; then
  case "${CHECKPOINT_MODE}" in
    percent)
      [[ "${CHECKPOINT_TARGET_VALUE}" =~ ^[0-9]+$ ]] \
        || fail "checkpoint percentage must be an integer between 1 and 99."
      if [ "${CHECKPOINT_TARGET_VALUE}" -le 0 ] || [ "${CHECKPOINT_TARGET_VALUE}" -ge 100 ]; then
        fail "checkpoint percentage must be between 1 and 99."
      fi
      CHECKPOINT_PERCENT="${CHECKPOINT_TARGET_VALUE}"
      ;;
    delay)
      is_nonnegative_number "${CHECKPOINT_TARGET_VALUE}" \
        || fail "checkpoint delay must be a nonnegative number."
      python3 - "${CHECKPOINT_TARGET_VALUE}" <<'PY' \
        || fail "checkpoint delay must be greater than zero."
import sys
raise SystemExit(0 if float(sys.argv[1]) > 0 else 1)
PY
      CHECKPOINT_DELAY_SECONDS="${CHECKPOINT_TARGET_VALUE}"
      ;;
    *)
      fail "CR checkpoint mode must be percent or delay; received '${CHECKPOINT_MODE}'."
      ;;
  esac
fi

if [ "${BENCHMARK}" = "bt" ]; then
  SQRT_NP="$(python3 - "${NP}" <<'PY'
import math
import sys
np = int(sys.argv[1])
root = math.isqrt(np)
print(root if root * root == np else -1)
PY
)"
  [ "${SQRT_NP}" != "-1" ] \
    || fail "NPB BT requires a perfect-square rank count: 1, 4, 9, 16, 25, ..."
fi

if [ "${BENCHMARK}" = "cg" ] && (( NP < 1 || (NP & (NP - 1)) != 0 )); then
  fail "NPB CG requires a power-of-two rank count: 1, 2, 4, 8, 16, ..."
fi

[ -f "${ENV_FILE}" ] \
  || fail "DMTCP/MPICH environment helper not found: ${ENV_FILE}"
# shellcheck disable=SC1090
source "${ENV_FILE}"

if ! verify_single_node_stack; then
  fail "the expected single-node DMTCP/MPICH stack is not active."
fi

for command_name in mpirun dmtcp_coordinator dmtcp_launch dmtcp_command python3 pgrep ps flock; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "required command unavailable after sourcing ${ENV_FILE}: ${command_name}"
done

mkdir -p "${BINARY_ROOT}" "${RESULTS_ROOT}"
BINARY_ROOT="$(cd -- "${BINARY_ROOT}" && pwd)"
RESULTS_ROOT="$(cd -- "${RESULTS_ROOT}" && pwd)"
NPB_BIN="${BINARY_ROOT}/${BENCHMARK}.${NPB_CLASS}.x"

[ -x "${NPB_BIN}" ] \
  || fail "missing benchmark binary: ${NPB_BIN}; run build_npb_bt_cg_d.sh first."

if [ "${SCENARIO}" = "cr" ] && [ "${CHECKPOINT_MODE}" = "percent" ]; then
  BASELINE_REFERENCE_SECONDS="$(resolve_percentage_baseline 2>/dev/null || true)"
  if [ -z "${BASELINE_REFERENCE_SECONDS}" ]; then
    fail "percentage mode requires successful matching baseline runs under ${RESULTS_ROOT} or BASELINE_REFERENCE_SECONDS=<seconds>."
  fi

  CHECKPOINT_BASELINE_SECONDS="${BASELINE_REFERENCE_SECONDS}"
  export BASELINE_REFERENCE_SECONDS
  CHECKPOINT_DELAY_SECONDS="$(python3 - "${CHECKPOINT_BASELINE_SECONDS}" "${CHECKPOINT_PERCENT}" <<'PY'
import sys
baseline = float(sys.argv[1])
percentage = int(sys.argv[2])
print(f'{baseline * percentage / 100.0:.9f}')
PY
)"
fi

if [ "${SCENARIO}" = "baseline" ]; then
  RUN_NAME="${BENCHMARK}${NPB_CLASS}_np${NP}_baseline_rep${REP}"
elif [ "${CHECKPOINT_MODE}" = "percent" ]; then
  RUN_NAME="${BENCHMARK}${NPB_CLASS}_np${NP}_cr_p${CHECKPOINT_PERCENT}_rep${REP}"
else
  CHECKPOINT_LABEL="$(python3 - "${CHECKPOINT_DELAY_SECONDS}" <<'PY'
import sys
print(sys.argv[1].replace('.', 'p'))
PY
)"
  RUN_NAME="${BENCHMARK}${NPB_CLASS}_np${NP}_cr_t${CHECKPOINT_LABEL}_rep${REP}"
fi

RUN_DIR="${RESULTS_ROOT}/${RUN_NAME}"

if [ -e "${RUN_DIR}" ]; then
  case "${EXISTING_RUN_POLICY}" in
    resume)
      if [ -f "${RUN_DIR}/SUCCESS.marker" ]; then
        phase setup "Skipping successfully completed run: ${RUN_DIR}"
        exit 0
      fi
      phase setup "Replacing incomplete run directory: ${RUN_DIR}"
      rm -rf -- "${RUN_DIR}"
      ;;
    replace)
      phase setup "Replacing existing run directory: ${RUN_DIR}"
      rm -rf -- "${RUN_DIR}"
      ;;
    error)
      fail "run directory already exists: ${RUN_DIR}"
      ;;
  esac
fi

mkdir -p "${RUN_DIR}"
cd "${RUN_DIR}"

phase cleanup "Removing abandoned DMTCP/MPI/NPB processes before this experiment."
if ! "${SCRIPT_DIR}/kill_dmtcp_processes.sh" > pre_run_cleanup.log 2>&1; then
  cat pre_run_cleanup.log >&2
  fail "pre-run process cleanup failed."
fi
cat pre_run_cleanup.log
printf '%s\n' "RUNNING" > run_status.txt

# Runtime profile of the validated single-node workflow.
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
export MPIR_CVAR_ENABLE_GPU="${MPIR_CVAR_ENABLE_GPU:-0}"
export DMTCP_SIGCKPT="${DMTCP_EXPERIMENT_SIGNAL:-30}"
unset DISPLAY
unset XAUTHORITY

APP_PID=""
COORD_PID=""
RESTORED_PID=""
PORT=""
CLEANUP_DONE=0
RESTORE_PORT_RESERVATION_ACTIVE=0
RESTORE_PORT_RESERVATION_LOCK_FD=""
RESTORE_PORT_RESERVATION_STATE="${RUN_DIR}/restore_port_reservation_state.json"
EXPECTED_DMTCP_CLIENTS=$((NP + 2))

now_ns() {
  date +%s%N
}

elapsed_s() {
  python3 - "$1" "$2" <<'PY'
import sys
print(f"{(int(sys.argv[2]) - int(sys.argv[1])) / 1e9:.9f}")
PY
}

write_elapsed() {
  elapsed_s "$2" "$3" > "$1"
}

human_seconds() {
  python3 - "$1" <<'PY'
import sys
seconds = float(sys.argv[1])
if seconds < 60:
    print(f"{seconds:.2f} s")
elif seconds < 3600:
    minutes = int(seconds // 60)
    remain = seconds - minutes * 60
    print(f"{minutes}m {remain:.1f}s")
else:
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    remain = seconds % 60
    print(f"{hours}h {minutes}m {remain:.0f}s")
PY
}

count_regex() {
  printf '%s\n' "$1" | grep -Ec "$2" || true
}

dmtcp_list() {
  dmtcp_command --coord-port "${PORT}" --list 2>/dev/null || true
}

pid_is_active() {
  local pid="$1"
  local state
  kill -0 "${pid}" 2>/dev/null || return 1
  state="$(ps -o stat= -p "${pid}" 2>/dev/null | awk '{print $1}')"
  [[ -n "${state}" && "${state}" != Z* ]]
}

wait_for_coordinator() {
  local deadline=$((SECONDS + COORDINATOR_START_TIMEOUT_SECONDS))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    if dmtcp_command --coord-port "${PORT}" --list >/dev/null 2>&1; then
      return 0
    fi
    if [ -n "${COORD_PID}" ] && ! pid_is_active "${COORD_PID}"; then
      return 1
    fi
    sleep 0.1
  done
  return 1
}

select_random_port() {
  python3 - "${DMTCP_PORT_MIN}" "${DMTCP_PORT_MAX}" <<'PY'
import random
import socket
import sys
low, high = map(int, sys.argv[1:])
for _ in range(200):
    port = random.randint(low, high)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            continue
    print(port)
    raise SystemExit(0)
raise SystemExit("could not find a free coordinator port")
PY
}

list_process_tree_postorder() {
  local root_pid="$1"
  local child_pid
  while read -r child_pid; do
    [ -n "${child_pid}" ] && list_process_tree_postorder "${child_pid}"
  done < <(pgrep -P "${root_pid}" 2>/dev/null || true)
  echo "${root_pid}"
}

terminate_process_tree() {
  local root_pid="$1"
  local signal_name="$2"
  local -a ids=()
  [ -n "${root_pid}" ] || return 0
  mapfile -t ids < <(list_process_tree_postorder "${root_pid}")
  [ "${#ids[@]}" -eq 0 ] || kill "-${signal_name}" -- "${ids[@]}" 2>/dev/null || true
}

release_restore_ports() {
  local release_status=0

  if [ "${RESTORE_PORT_RESERVATION_ACTIVE}" -eq 1 ] && \
     [ -f "${RESTORE_PORT_RESERVATION_STATE}" ]; then
    phase restore "Restoring the previous net.ipv4.ip_local_reserved_ports value."
    set +e
    python3 "${RESTORE_PORT_RESERVATION_HELPER}" release \
      --state "${RESTORE_PORT_RESERVATION_STATE}" \
      --sysctl-path "${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH}" \
      --release-output "${RUN_DIR}/restore_port_reservation_released_value.txt" \
      > "${RUN_DIR}/restore_port_reservation_release.log" 2>&1
    release_status=$?
    set -e
    cat "${RUN_DIR}/restore_port_reservation_release.log" 2>/dev/null || true
    if [ "${release_status}" -eq 0 ]; then
      printf '%s\n' "RELEASED" > "${RUN_DIR}/restore_port_reservation_status.txt"
      RESTORE_PORT_RESERVATION_ACTIVE=0
    else
      printf '%s\n' "RELEASE_FAILED" > "${RUN_DIR}/restore_port_reservation_status.txt"
    fi
  fi

  if [ "${release_status}" -eq 0 ] && \
     [ -n "${RESTORE_PORT_RESERVATION_LOCK_FD}" ]; then
    flock -u "${RESTORE_PORT_RESERVATION_LOCK_FD}" 2>/dev/null || true
    eval "exec ${RESTORE_PORT_RESERVATION_LOCK_FD}>&-"
    RESTORE_PORT_RESERVATION_LOCK_FD=""
  fi

  return "${release_status}"
}

reserve_restore_ports() {
  local lock_parent
  local prepare_status

  if [ "${RESTORE_RESERVE_ORIGINAL_TCP_PORTS}" = "false" ]; then
    phase restore "Captured TCP-listener port reservation is disabled by configuration."
    printf '%s\n' "DISABLED" > "${RUN_DIR}/restore_port_reservation_status.txt"
    return 0
  fi

  [ -r "${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH}" ] \
    || fail "cannot read restore port-reservation sysctl: ${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH}"
  [ -w "${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH}" ] \
    || fail "cannot write restore port-reservation sysctl: ${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH}; run with sufficient privilege or set RESTORE_RESERVE_ORIGINAL_TCP_PORTS=false for a deliberate comparison."

  lock_parent="$(dirname -- "${RESTORE_PORT_RESERVATION_LOCK_FILE}")"
  mkdir -p -- "${lock_parent}"
  exec {RESTORE_PORT_RESERVATION_LOCK_FD}> "${RESTORE_PORT_RESERVATION_LOCK_FILE}"
  if ! flock -w "${RESTORE_PORT_RESERVATION_LOCK_TIMEOUT_SECONDS}" \
      "${RESTORE_PORT_RESERVATION_LOCK_FD}"; then
    eval "exec ${RESTORE_PORT_RESERVATION_LOCK_FD}>&-"
    RESTORE_PORT_RESERVATION_LOCK_FD=""
    fail "timed out waiting for restore port-reservation lock: ${RESTORE_PORT_RESERVATION_LOCK_FILE}"
  fi

  phase restore "Reserving captured IPv4 TCP listener ports against temporary bind(port=0) allocation."
  set +e
  python3 "${RESTORE_PORT_RESERVATION_HELPER}" prepare \
    --capture-state "${CLEANUP_STATE}" \
    --state "${RESTORE_PORT_RESERVATION_STATE}" \
    --sysctl-path "${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH}" \
    --ports-output "${RUN_DIR}/restore_reserved_tcp_listener_ports.txt" \
    --original-output "${RUN_DIR}/restore_port_reservation_original_value.txt" \
    --applied-output "${RUN_DIR}/restore_port_reservation_applied_value.txt" \
    > "${RUN_DIR}/restore_port_reservation_prepare.log" 2>&1
  prepare_status=$?
  set -e
  cat "${RUN_DIR}/restore_port_reservation_prepare.log"
  if [ "${prepare_status}" -ne 0 ]; then
    printf '%s\n' "PREPARE_FAILED" > "${RUN_DIR}/restore_port_reservation_status.txt"
    flock -u "${RESTORE_PORT_RESERVATION_LOCK_FD}" 2>/dev/null || true
    eval "exec ${RESTORE_PORT_RESERVATION_LOCK_FD}>&-"
    RESTORE_PORT_RESERVATION_LOCK_FD=""
    fail "could not reserve captured TCP listener ports before restore."
  fi

  RESTORE_PORT_RESERVATION_ACTIVE=1
  printf '%s\n' "ACTIVE" > "${RUN_DIR}/restore_port_reservation_status.txt"
}

cleanup() {
  if [ "${CLEANUP_DONE}" -eq 1 ]; then
    return
  fi
  CLEANUP_DONE=1
  set +e

  phase cleanup "Cleaning processes associated with this run."
  if [ -n "${PORT}" ]; then
    dmtcp_command --coord-port "${PORT}" --kill >/dev/null 2>&1 || true
  fi

  terminate_process_tree "${RESTORED_PID}" TERM
  terminate_process_tree "${APP_PID}" TERM
  terminate_process_tree "${COORD_PID}" TERM
  sleep 1
  terminate_process_tree "${RESTORED_PID}" KILL
  terminate_process_tree "${APP_PID}" KILL
  terminate_process_tree "${COORD_PID}" KILL

  for pid in "${RESTORED_PID}" "${APP_PID}" "${COORD_PID}"; do
    [ -z "${pid}" ] || wait "${pid}" 2>/dev/null || true
  done
  release_restore_ports || true
  set -e
}

collect_diagnostics() {
  local prefix="$1"
  phase diagnostics "Collecting failure diagnostics with prefix '${prefix}'."

  dmtcp_list > "${prefix}_dmtcp_list.txt" 2>&1 || true
  ps -eo pid,ppid,stat,pcpu,pmem,etime,wchan:28,cmd \
    | grep -E "dmtcp|hydra|mpiexec|mpirun|bt\.${NPB_CLASS}\.x|cg\.${NPB_CLASS}\.x" \
    | grep -v grep > "${prefix}_processes.txt" 2>&1 || true
  if command -v ss >/dev/null 2>&1; then
    ss -tanup > "${prefix}_inet_sockets.txt" 2>&1 || true
    ss -xanp > "${prefix}_unix_sockets.txt" 2>&1 || true
  fi

  {
    echo "Timestamp: $(date -Is)"
    echo "Output root: ${OUTPUT_ROOT}"
    echo "Run directory: ${RUN_DIR}"
    echo "Benchmark: ${BENCHMARK^^}.${NPB_CLASS}"
    echo "MPI ranks: ${NP}"
    echo "Scenario: ${SCENARIO}"
    echo "Checkpoint target: ${CHECKPOINT_DELAY_SECONDS} seconds"
    echo "Port: ${PORT}"
    echo "Expected DMTCP clients: ${EXPECTED_DMTCP_CLIENTS}"
    echo
    echo "Directory contents:"
    ls -lah . || true
    echo
    for log_file in coordinator.log stdout.log stderr.log \
      stdout_before_ckpt.log stderr_before_ckpt.log \
      stdout_after_restore.log stderr_after_restore.log; do
      echo "===== ${log_file} ====="
      tail -n 250 "${log_file}" 2>/dev/null || true
      echo
    done
  } > "${prefix}_diagnostics.txt" 2>&1 || true
}

verify_npb_output() {
  grep -Eiq 'Verification[[:space:]]*=[[:space:]]*SUCCESSFUL' "$@"
}

monitor_background_process() {
  local pid="$1"
  local label="$2"
  local phase_start_ns="$3"
  local interval="${4:-30}"
  local overall_start_ns="${5:-}"
  local next_report=$((SECONDS + interval))

  while pid_is_active "${pid}"; do
    sleep 1

    if [ "${SECONDS}" -ge "${next_report}" ]; then
      local current_ns
      local phase_elapsed

      current_ns="$(now_ns)"
      phase_elapsed="$(elapsed_s "${phase_start_ns}" "${current_ns}")"

      if [ -n "${overall_start_ns}" ]; then
        local overall_elapsed

        overall_elapsed="$(elapsed_s "${overall_start_ns}" "${current_ns}")"
        phase "${label}" \
          "Still running; elapsed since latest restore: $(human_seconds "${phase_elapsed}") | since initial launch: $(human_seconds "${overall_elapsed}")."
      else
        phase "${label}" \
          "Still running; elapsed $(human_seconds "${phase_elapsed}")."
      fi

      next_report=$((SECONDS + interval))
    fi
  done
}

wait_until_checkpoint_target() {
  local pid="$1"
  local target="$2"
  local start_ns="$3"
  local timer_pid
  local next_report=$((SECONDS + PROGRESS_INTERVAL_SECONDS))

  sleep "${target}" &
  timer_pid=$!

  while pid_is_active "${timer_pid}"; do
    if ! pid_is_active "${pid}"; then
      kill -TERM "${timer_pid}" 2>/dev/null || true
      wait "${timer_pid}" 2>/dev/null || true
      return 1
    fi

    if [ "${SECONDS}" -ge "${next_report}" ]; then
      local elapsed
      elapsed="$(elapsed_s "${start_ns}" "$(now_ns)")"
      phase run "Application is still running; elapsed $(human_seconds "${elapsed}") toward checkpoint target ${target}s."
      next_report=$((SECONDS + PROGRESS_INTERVAL_SECONDS))
    fi
    sleep 0.2
  done

  wait "${timer_pid}" 2>/dev/null || true
  return 0
}

checkpoint_storage_metrics() {
  python3 - "${NP}" <<'PY'
from pathlib import Path
import sys

np = int(sys.argv[1])

def entry_size(path: Path) -> int:
    if path.is_file() or path.is_symlink():
        return path.stat().st_size
    return sum(item.stat().st_size for item in path.rglob('*') if item.is_file())

entries = list(Path('.').glob('ckpt_*'))
size_bytes = sum(entry_size(path) for path in entries)
size_gb = size_bytes / 1_000_000_000
size_gib = size_bytes / (1024 ** 3)
mean_rank_gb = size_gb / np if np else 0.0
mean_rank_gib = size_gib / np if np else 0.0

Path('checkpoint_size_bytes.txt').write_text(f'{size_bytes}\n')
Path('checkpoint_size_gb.txt').write_text(f'{size_gb:.9f}\n')
Path('checkpoint_size_gib.txt').write_text(f'{size_gib:.9f}\n')
Path('checkpoint_mean_per_rank_gb.txt').write_text(f'{mean_rank_gb:.9f}\n')
Path('checkpoint_mean_per_rank_gib.txt').write_text(f'{mean_rank_gib:.9f}\n')
PY
}

find_baseline_reference() {
  if [[ "${BASELINE_REFERENCE_SECONDS:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s\n' "${BASELINE_REFERENCE_SECONDS}"
    return 0
  fi

  python3 - "${RESULTS_ROOT}" "${BENCHMARK}" "${NPB_CLASS}" "${NP}" <<'PY'
from pathlib import Path
import statistics
import sys

root = Path(sys.argv[1])
benchmark, npb_class, np = sys.argv[2], sys.argv[3], int(sys.argv[4])
values = []
for run_dir in root.glob(f'{benchmark}{npb_class}_np{np}_baseline_rep*'):
    if not run_dir.is_dir():
        continue
    success_marker = run_dir / 'SUCCESS.marker'
    total = run_dir / 'total_seconds.txt'
    if success_marker.is_file() and total.is_file():
        values.append(float(total.read_text().strip()))
if not values:
    raise SystemExit(1)
print(f'{statistics.mean(values):.9f}')
PY
}

write_overhead_metrics() {
  local total_seconds="$1"
  local baseline_reference=""

  if [ "${SCENARIO}" = "baseline" ]; then
    baseline_reference="${total_seconds}"
  else
    baseline_reference="$(find_baseline_reference 2>/dev/null || true)"
  fi

  if [ -n "${baseline_reference}" ]; then
    printf '%s\n' "${baseline_reference}" > baseline_reference_seconds.txt
    python3 - "${total_seconds}" "${baseline_reference}" <<'PY'
from pathlib import Path
import sys

total = float(sys.argv[1])
baseline = float(sys.argv[2])
overhead = total - baseline
percent = overhead / baseline * 100 if baseline else 0.0

Path('total_dmtcp_related_overhead_seconds.txt').write_text(f'{overhead:.9f}\n')
Path('total_dmtcp_related_overhead_percent.txt').write_text(f'{percent:.9f}\n')
PY
  else
    echo "N/A" > baseline_reference_seconds.txt
    echo "N/A" > total_dmtcp_related_overhead_seconds.txt
    echo "N/A" > total_dmtcp_related_overhead_percent.txt
  fi
}

write_checkpoint_restore_overhead_metrics() {
  python3 <<'PY'
from pathlib import Path


def read_number(name: str) -> float:
    return float(Path(name).read_text().strip())


pre_restore_cleanup = read_number('pre_restore_cleanup_seconds.txt')

procedure_overhead = sum(
    (
        read_number('checkpoint_seconds.txt'),
        read_number('post_checkpoint_stabilization_seconds.txt'),
        pre_restore_cleanup,
        read_number('dmtcp_restore_seconds.txt'),
    )
)

workflow_text = f'{procedure_overhead:.9f}\n'
Path('checkpoint_restore_workflow_overhead_seconds.txt').write_text(workflow_text)

total_text = Path('total_dmtcp_related_overhead_seconds.txt').read_text().strip()

if total_text == 'N/A':
    residual_text = 'N/A\n'
else:
    total_overhead = float(total_text)
    residual_difference = total_overhead - procedure_overhead
    residual_text = f'{residual_difference:.9f}\n'

Path('residual_dmtcp_runtime_difference_seconds.txt').write_text(residual_text)
PY
}

write_execution_summary() {
  local total
  total="$(<total_seconds.txt)"

  {
    echo "Execution summary"
    echo "================="
    echo "Benchmark: ${BENCHMARK^^}.${NPB_CLASS}"
    echo "MPI ranks: ${NP}"
    echo "Scenario: ${SCENARIO}"
    echo "Run directory: ${RUN_DIR}"
    echo
    printf 'Total duration: %.6f seconds\n' "${total}"

    if [ "${SCENARIO}" = "baseline" ]; then
      echo "Checkpoint/restore metrics: N/A (baseline execution; not run under DMTCP)"
    else
      local checkpoint restore stabilization cleanup shutdown endpoint_verification final_grace
      local restore_attempt_count restore_retry_count successful_restore_attempt
      local size_total size_rank baseline workflow_overhead
      local total_overhead total_overhead_pct residual_difference

      checkpoint="$(<checkpoint_seconds.txt)"
      restore="$(<dmtcp_restore_seconds.txt)"
      restore_attempt_count="$(<restore_attempt_count.txt)"
      restore_retry_count="$(<restore_retry_count.txt)"
      successful_restore_attempt="$(<successful_restore_attempt_seconds.txt)"
      stabilization="$(<post_checkpoint_stabilization_seconds.txt)"
      cleanup="$(<pre_restore_cleanup_seconds.txt)"
      shutdown="$(<original_shutdown_seconds.txt)"
      endpoint_verification="$(<pre_restore_endpoint_verification_seconds.txt)"
      final_grace="$(<pre_restore_final_grace_seconds.txt)"
      size_total="$(<checkpoint_size_gb.txt)"
      size_rank="$(<checkpoint_mean_per_rank_gb.txt)"
      baseline="$(<baseline_reference_seconds.txt)"
      workflow_overhead="$(<checkpoint_restore_workflow_overhead_seconds.txt)"
      total_overhead="$(<total_dmtcp_related_overhead_seconds.txt)"
      total_overhead_pct="$(<total_dmtcp_related_overhead_percent.txt)"
      residual_difference="$(<residual_dmtcp_runtime_difference_seconds.txt)"

      printf 'Size of checkpoints: %.6f GB total | %.6f GB mean per application rank\n' "${size_total}" "${size_rank}"
      printf 'Time required for the checkpoint step: %.6f seconds\n' "${checkpoint}"
      printf 'Time required for the complete restore phase: %.6f seconds (%s attempt(s), %s retry/retries)\n' \
        "${restore}" "${restore_attempt_count}" "${restore_retry_count}"
      printf 'Time required for the successful restore attempt: %.6f seconds\n' "${successful_restore_attempt}"
      printf 'DMTCP checkpoint/restore workflow overhead: %.6f seconds\n' "${workflow_overhead}"
      printf '  Included phases: checkpoint %.6f + post-checkpoint stabilization %.6f + adaptive pre-restore cleanup %.6f + restore %.6f seconds\n' \
        "${checkpoint}" "${stabilization}" "${cleanup}" "${restore}"
      printf '  Adaptive cleanup detail: captured-process shutdown %.6f + endpoint verification %.6f + final verified-clear grace %.6f seconds\n' \
        "${shutdown}" "${endpoint_verification}" "${final_grace}"

      if [ "${total_overhead}" = "N/A" ]; then
        echo "Total DMTCP-related overhead: N/A (no successful baseline was available)"
        echo "Residual DMTCP runtime difference: N/A (no successful baseline was available)"
      else
        python3 - "${total_overhead}" "${total_overhead_pct}" "${baseline}" <<'PY'
import sys
value = float(sys.argv[1])
percent = float(sys.argv[2])
baseline = float(sys.argv[3])
magnitude = abs(value)
epsilon = 0.5e-6
if value < -epsilon:
    interpretation = f"complete DMTCP execution was {magnitude:.6f} seconds faster than the baseline"
elif value > epsilon:
    interpretation = f"complete DMTCP execution was {magnitude:.6f} seconds slower than the baseline"
else:
    interpretation = "no measurable total difference from the baseline"
print(
    f"Total DMTCP-related overhead: {value:.6f} seconds "
    f"({percent:.3f}% compared with baseline mean {baseline:.6f} seconds; {interpretation})"
)
PY
        python3 - "${residual_difference}" <<'PY'
import sys
value = float(sys.argv[1])
magnitude = abs(value)
epsilon = 0.5e-6
if value < -epsilon:
    print(f"Residual DMTCP runtime difference: {value:.6f} seconds ({magnitude:.6f} seconds faster than baseline outside the measured checkpoint/restore workflow)")
elif value > epsilon:
    print(f"Residual DMTCP runtime difference: {value:.6f} seconds ({magnitude:.6f} seconds slower than baseline outside the measured checkpoint/restore workflow)")
else:
    print("Residual DMTCP runtime difference: 0.000000 seconds (no measurable difference outside the measured checkpoint/restore workflow)")
PY
      fi
    fi
  } > execution_summary.txt
}

mark_success() {
  local temporary_marker=".SUCCESS.marker.$$"
  {
    echo "status=SUCCESS"
    echo "run_name=${RUN_NAME}"
    echo "completed_at=$(date -Is)"
    echo "npb_verification=SUCCESSFUL"
  } > "${temporary_marker}"
  mv -f -- "${temporary_marker}" SUCCESS.marker
}

delete_checkpoint_artifacts() {
  if [ "${CHECKPOINT_CLEANUP_MODE}" != "delete-checkpoints" ]; then
    phase cleanup "Keeping checkpoint artifacts at ${RUN_DIR}."
    return
  fi

  phase cleanup "Deleting checkpoint artifacts after all size metrics were recorded."
  {
    echo "Deleted at: $(date -Is)"
    find . -maxdepth 1 \( -name 'ckpt_*' -o -name 'dmtcp_restart_script*.sh*' \) -print
  } > deleted_checkpoint_artifacts.txt

  find . -maxdepth 1 \( -name 'ckpt_*' -o -name 'dmtcp_restart_script*.sh*' \) \
    -exec rm -rf -- {} +
}


copy_restore_attempt_to_canonical_logs() {
  local attempt_dir="$1"

  cp -f -- "${attempt_dir}/stdout.log" stdout_after_restore.log 2>/dev/null || true
  cp -f -- "${attempt_dir}/stderr.log" stderr_after_restore.log 2>/dev/null || true
  cp -f -- "${attempt_dir}/dmtcp_list_latest.txt" \
    dmtcp_list_after_restore_latest.txt 2>/dev/null || true
  cp -f -- "${attempt_dir}/dmtcp_list_confirmed.txt" \
    dmtcp_list_after_restore_confirmed.txt 2>/dev/null || true
}

run_restore_attempt() {
  local attempt_number="$1"
  local attempt_dir="$2"
  local attempt_start_ns
  local attempt_end_ns
  local restore_deadline
  local last_restore_report
  local bind_failure_first_seen_seconds=""
  local bind_failure_last_count=0
  local bind_failure_pattern='Address already in use|Bind failed'
  local after_list total_after running_after restarting_after
  local confirm_list total_confirm running_confirm
  local bind_failure_count
  local restored_status

  mkdir -p "${attempt_dir}"
  ATTEMPT_FAILURE_KIND=""
  ATTEMPT_FAILURE_MESSAGE=""
  RESTORE_FOUND=0
  RUNNING_AFTER_RESTORE=0

  phase restore "Attempt ${attempt_number}/${RESTORE_MAX_ATTEMPTS}: launching the generated restart script from the existing checkpoint."
  attempt_start_ns="$(now_ns)"
  printf '%s\n' "${attempt_start_ns}" > "${attempt_dir}/start_time_ns.txt"
  printf '%s\n' "$(date -Is)" > "${attempt_dir}/started_at.txt"

  # Do not pass coordinator options here. This remains identical to the
  # validated single-node restart invocation.
  bash "${RESTART_SCRIPT}" \
    > "${attempt_dir}/stdout.log" 2> "${attempt_dir}/stderr.log" &
  RESTORED_PID=$!
  printf '%s\n' "${RESTORED_PID}" > "${attempt_dir}/restart_wrapper_pid.txt"

  restore_deadline=$((SECONDS + DMTCP_RESTORE_TIMEOUT_SECONDS))
  last_restore_report=$((SECONDS - RESTORE_PROGRESS_INTERVAL_SECONDS))

  while pid_is_active "${RESTORED_PID}"; do
    after_list="$(dmtcp_list)"
    printf '%s\n' "${after_list}" > "${attempt_dir}/dmtcp_list_latest.txt"
    total_after="$(count_regex "${after_list}" 'WorkerState::')"
    running_after="$(count_regex "${after_list}" 'WorkerState::RUNNING')"
    restarting_after="$(count_regex "${after_list}" 'WorkerState::RESTARTING')"

    if [ "${SECONDS}" -ge $((last_restore_report + RESTORE_PROGRESS_INTERVAL_SECONDS)) ]; then
      phase restore "Attempt ${attempt_number}/${RESTORE_MAX_ATTEMPTS}: ${running_after}/${EXPECTED_DMTCP_CLIENTS} clients RUNNING; ${restarting_after} RESTARTING; ${total_after} registered."
      last_restore_report="${SECONDS}"
    fi

    if [ "${total_after}" -ge "${EXPECTED_DMTCP_CLIENTS}" ] && \
       [ "${running_after}" -ge "${EXPECTED_DMTCP_CLIENTS}" ]; then
      sleep 0.2
      confirm_list="$(dmtcp_list)"
      printf '%s\n' "${confirm_list}" > "${attempt_dir}/dmtcp_list_confirmed.txt"
      total_confirm="$(count_regex "${confirm_list}" 'WorkerState::')"
      running_confirm="$(count_regex "${confirm_list}" 'WorkerState::RUNNING')"
      if [ "${total_confirm}" -ge "${EXPECTED_DMTCP_CLIENTS}" ] && \
         [ "${running_confirm}" -ge "${EXPECTED_DMTCP_CLIENTS}" ]; then
        RESTORE_FOUND=1
        RUNNING_AFTER_RESTORE="${running_confirm}"
        break
      fi
    fi

    bind_failure_count="$(grep -Eic "${bind_failure_pattern}" "${attempt_dir}/stderr.log" 2>/dev/null || true)"
    if [ "${bind_failure_count}" -gt 0 ]; then
      if [ -z "${bind_failure_first_seen_seconds}" ]; then
        bind_failure_first_seen_seconds="${SECONDS}"
        phase restore "Attempt ${attempt_number}/${RESTORE_MAX_ATTEMPTS}: detected bind-related errors; allowing ${RESTORE_BIND_FAILURE_ABORT_SECONDS}s for transient recovery."
      fi
      if [ "${bind_failure_count}" -ne "${bind_failure_last_count}" ]; then
        printf '%s\n' "${bind_failure_count}" > "${attempt_dir}/bind_failure_count.txt"
        bind_failure_last_count="${bind_failure_count}"
      fi
      if python3 - "${SECONDS}" "${bind_failure_first_seen_seconds}" "${RESTORE_BIND_FAILURE_ABORT_SECONDS}" <<'PY'
import sys
now, first, threshold = map(float, sys.argv[1:])
raise SystemExit(0 if now - first >= threshold else 1)
PY
      then
        {
          echo "First detected at shell elapsed second: ${bind_failure_first_seen_seconds}"
          echo "Aborted at shell elapsed second: ${SECONDS}"
          echo "Configured persistence threshold: ${RESTORE_BIND_FAILURE_ABORT_SECONDS}"
          echo "Matching stderr lines: ${bind_failure_count}"
          grep -Ein "${bind_failure_pattern}" "${attempt_dir}/stderr.log" 2>/dev/null || true
        } > "${attempt_dir}/persistent_bind_failure.txt"
        ATTEMPT_FAILURE_KIND="persistent_bind_failure"
        ATTEMPT_FAILURE_MESSAGE="persistent bind/address-in-use errors"
        break
      fi
    fi

    if [ "${SECONDS}" -ge "${restore_deadline}" ]; then
      ATTEMPT_FAILURE_KIND="timeout"
      ATTEMPT_FAILURE_MESSAGE="did not reach ${EXPECTED_DMTCP_CLIENTS} RUNNING clients within ${DMTCP_RESTORE_TIMEOUT_SECONDS} seconds"
      break
    fi
    sleep 0.2
  done

  if [ "${RESTORE_FOUND}" -eq 1 ]; then
    attempt_end_ns="$(now_ns)"
    write_elapsed "${attempt_dir}/duration_seconds.txt" "${attempt_start_ns}" "${attempt_end_ns}"
    printf '%s\n' "SUCCESS" > "${attempt_dir}/status.txt"
    printf '%s\n' "all expected clients reached RUNNING" > "${attempt_dir}/reason.txt"
    copy_restore_attempt_to_canonical_logs "${attempt_dir}"
    printf '%s\tSUCCESS\t%s\t%s\n' \
      "${attempt_number}" \
      "$(<"${attempt_dir}/duration_seconds.txt")" \
      "all_expected_clients_running" \
      >> restore_attempts_summary.tsv
    return 0
  fi

  if [ -z "${ATTEMPT_FAILURE_KIND}" ]; then
    set +e
    wait "${RESTORED_PID}"
    restored_status=$?
    set -e
    RESTORED_PID=""
    ATTEMPT_FAILURE_KIND="restart_script_exited"
    ATTEMPT_FAILURE_MESSAGE="restart script exited with status ${restored_status} before all clients were RUNNING"
    printf '%s\n' "${restored_status}" > "${attempt_dir}/restart_wrapper_exit_status.txt"
  fi

  attempt_end_ns="$(now_ns)"
  write_elapsed "${attempt_dir}/duration_seconds.txt" "${attempt_start_ns}" "${attempt_end_ns}"
  printf '%s\n' "FAILED" > "${attempt_dir}/status.txt"
  printf '%s\n' "${ATTEMPT_FAILURE_KIND}" > "${attempt_dir}/failure_kind.txt"
  printf '%s\n' "${ATTEMPT_FAILURE_MESSAGE}" > "${attempt_dir}/reason.txt"
  copy_restore_attempt_to_canonical_logs "${attempt_dir}"
  collect_diagnostics "${attempt_dir}/${ATTEMPT_FAILURE_KIND}"
  printf '%s\tFAILED\t%s\t%s\n' \
    "${attempt_number}" \
    "$(<"${attempt_dir}/duration_seconds.txt")" \
    "${ATTEMPT_FAILURE_KIND}" \
    >> restore_attempts_summary.tsv
  return 1
}

cleanup_failed_restore_attempt() {
  local attempt_number="$1"
  local attempt_dir="$2"
  local retry_cleanup_dir="${attempt_dir}/retry_cleanup"
  local cleanup_state="${retry_cleanup_dir}/captured_state.json"
  local capture_status=1
  local adaptive_status=1
  local wrapper_status=0

  mkdir -p "${retry_cleanup_dir}"
  phase cleanup "Cleaning failed restore attempt ${attempt_number}/${RESTORE_MAX_ATTEMPTS} before reusing the same checkpoint."

  if [ -n "${RESTORED_PID}" ] && pid_is_active "${RESTORED_PID}"; then
    set +e
    python3 "${ADAPTIVE_CLEANUP_HELPER}" capture \
      --root-pid "${RESTORED_PID}" \
      --state "${cleanup_state}" \
      --process-report "${retry_cleanup_dir}/captured_processes.tsv" \
      --socket-report "${retry_cleanup_dir}/captured_sockets.tsv" \
      > "${retry_cleanup_dir}/capture.log" 2>&1
    capture_status=$?
    set -e
  else
    printf '%s\n' "Restart wrapper was no longer active at retry cleanup." \
      > "${retry_cleanup_dir}/capture.log"
  fi

  if [ -n "${PORT}" ]; then
    dmtcp_command --coord-port "${PORT}" --kill >/dev/null 2>&1 || true
  fi

  if [ "${capture_status}" -eq 0 ]; then
    set +e
    python3 "${ADAPTIVE_CLEANUP_HELPER}" cleanup \
      --state "${cleanup_state}" \
      --metrics-dir "${retry_cleanup_dir}" \
      --timeout "${PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS}" \
      --poll "${PRE_RESTORE_CLEANUP_POLL_SECONDS}" \
      --force-kill-after "${PRE_RESTORE_FORCE_KILL_AFTER_SECONDS}" \
      --force-kill-grace "${PRE_RESTORE_FORCE_KILL_GRACE_SECONDS}" \
      --final-grace "0" \
      --report-interval "${PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS}" \
      > "${retry_cleanup_dir}/adaptive_cleanup.log" 2>&1
    adaptive_status=$?
    set -e
    cat "${retry_cleanup_dir}/adaptive_cleanup.log"
  else
    phase cleanup "Could not capture the failed restore process tree exactly; using emergency process cleanup and explicit retry grace."
  fi

  if [ -n "${RESTORED_PID}" ]; then
    terminate_process_tree "${RESTORED_PID}" TERM
    sleep 1
    terminate_process_tree "${RESTORED_PID}" KILL
    set +e
    wait "${RESTORED_PID}"
    wrapper_status=$?
    set -e
    printf '%s\n' "${wrapper_status}" > "${retry_cleanup_dir}/restart_wrapper_exit_status.txt"
    RESTORED_PID=""
  fi

  if ! "${SCRIPT_DIR}/kill_dmtcp_processes.sh" \
      > "${retry_cleanup_dir}/emergency_process_cleanup.log" 2>&1; then
    cat "${retry_cleanup_dir}/emergency_process_cleanup.log" >&2
    return 1
  fi

  if [ "${capture_status}" -eq 0 ] && [ "${adaptive_status}" -ne 0 ]; then
    return 1
  fi

  if python3 - "${RESTORE_RETRY_FINAL_GRACE_SECONDS}" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) > 0 else 1)
PY
  then
    phase cleanup "Applying final retry grace of ${RESTORE_RETRY_FINAL_GRACE_SECONDS} seconds after cleanup verification."
    sleep "${RESTORE_RETRY_FINAL_GRACE_SECONDS}"
  fi

  if [ "${capture_status}" -eq 0 ]; then
    printf '%s\n' "adaptive_endpoint_cleanup_plus_emergency_sweep" \
      > "${retry_cleanup_dir}/cleanup_mode.txt"
  else
    printf '%s\n' "fallback_process_cleanup" > "${retry_cleanup_dir}/cleanup_mode.txt"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Metadata and header
# ---------------------------------------------------------------------------
{
  echo "Run name: ${RUN_NAME}"
  echo "Start timestamp: $(date -Is)"
  echo "Benchmark: ${BENCHMARK}"
  echo "NPB class: ${NPB_CLASS}"
  echo "MPI ranks: ${NP}"
  echo "Scenario: ${SCENARIO}"
  echo "Repetition: ${REP}"
  echo "Checkpoint mode: ${CHECKPOINT_MODE}"
  echo "Checkpoint percentage: ${CHECKPOINT_PERCENT}"
  echo "Checkpoint baseline seconds: ${CHECKPOINT_BASELINE_SECONDS}"
  echo "Checkpoint target seconds: ${CHECKPOINT_DELAY_SECONDS}"
  echo "Output root: ${OUTPUT_ROOT}"
  echo "Results root: ${RESULTS_ROOT}"
  echo "Binary root: ${BINARY_ROOT}"
  echo "Binary: ${NPB_BIN}"
  echo "DMTCP commit: ${DMTCP_COMMIT:-unknown}"
  echo "DMTCP restore listener backlog: ${DMTCP_RESTORE_LISTEN_BACKLOG:-unknown}"
  echo "DMTCP restore listener paths patched: ${DMTCP_RESTORE_LISTENER_PATHS:-unknown}"
  echo "DMTCP duplex stream refill patch: ${DMTCP_DUPLEX_REFILL_PATCH_ACTIVE:-unknown}"
  echo "DMTCP IPC plugin: ${DMTCP_IPC_PLUGIN_PATH:-unknown}"
  echo "DMTCP IPC plugin SHA256: ${DMTCP_IPC_PLUGIN_SHA256:-unknown}"
  echo "Kernel net.core.somaxconn: $(cat /proc/sys/net/core/somaxconn)"
  echo "DMTCP signal: ${DMTCP_SIGCKPT}"
  echo "MPICH version: ${MPICH_VERSION:-unknown}"
  echo "MPICH device: ${MPICH_DEVICE:-unknown}"
  echo "MPICH_NO_LOCAL: ${MPICH_NO_LOCAL:-}"
  echo "MPIR_CVAR_ENABLE_GPU: ${MPIR_CVAR_ENABLE_GPU:-}"
  echo "Successful workflow: fresh coordinator, --exit-on-last, adaptive PID/start-time and socket cleanup, generated restart script without extra arguments"
  echo "Pre-restore cleanup timeout seconds: ${PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS}"
  echo "Pre-restore cleanup poll seconds: ${PRE_RESTORE_CLEANUP_POLL_SECONDS}"
  echo "Pre-restore force TERM after seconds: ${PRE_RESTORE_FORCE_KILL_AFTER_SECONDS}"
  echo "Pre-restore force KILL grace seconds: ${PRE_RESTORE_FORCE_KILL_GRACE_SECONDS}"
  echo "Pre-restore final grace seconds: ${PRE_RESTORE_FINAL_GRACE_SECONDS}"
  echo "Restore bind-failure abort seconds: ${RESTORE_BIND_FAILURE_ABORT_SECONDS}"
  echo "Restore maximum attempts: ${RESTORE_MAX_ATTEMPTS}"
  echo "Restore retry final verified-clear grace seconds: ${RESTORE_RETRY_FINAL_GRACE_SECONDS}"
  echo "Reserve original TCP listener ports during restore: ${RESTORE_RESERVE_ORIGINAL_TCP_PORTS}"
  echo "Restore port-reservation lock file: ${RESTORE_PORT_RESERVATION_LOCK_FILE}"
  echo "Restore port-reservation lock timeout seconds: ${RESTORE_PORT_RESERVATION_LOCK_TIMEOUT_SECONDS}"
  echo "Restore reserved-ports sysctl: ${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH}"
} > run_metadata.txt

printf '%s\n' "${CHECKPOINT_MODE}" > checkpoint_mode.txt
printf '%s\n' "${CHECKPOINT_PERCENT}" > checkpoint_percentage.txt
printf '%s\n' "${CHECKPOINT_BASELINE_SECONDS}" > checkpoint_baseline_seconds.txt
printf '%s\n' "${CHECKPOINT_DELAY_SECONDS}" > checkpoint_target_seconds.txt
printf '%s\n' "${DMTCP_SIGCKPT}" > dmtcp_signal.txt
printf '%s\n' "fresh" > coordinator_lifecycle.txt
printf '%s\n' "${DMTCP_COMMIT:-unknown}" > dmtcp_commit.txt
printf '%s\n' "${DMTCP_RESTORE_LISTEN_BACKLOG:-unknown}" > dmtcp_restore_listen_backlog.txt
cat /proc/sys/net/core/somaxconn > kernel_net_core_somaxconn.txt
printf '%s\n' "${MPICH_VERSION:-unknown}" > mpich_version.txt
printf '%s\n' "${MPICH_DEVICE:-unknown}" > mpich_device.txt

printf '%s\n' "============================================================"
printf '%s\n' "${BENCHMARK^^}.${NPB_CLASS} | MPI ranks=${NP} | scenario=${SCENARIO} | repetition=${REP}"
printf '%s\n' "Output directory: ${RUN_DIR}"
if [ "${SCENARIO}" = "cr" ]; then
  if [ "${CHECKPOINT_MODE}" = "percent" ]; then
    printf '%s\n' "Checkpoint target: ${CHECKPOINT_PERCENT}% of baseline ${CHECKPOINT_BASELINE_SECONDS}s = ${CHECKPOINT_DELAY_SECONDS}s after launch"
  else
    printf '%s\n' "Checkpoint target: ${CHECKPOINT_DELAY_SECONDS} seconds after launch (direct delay)"
  fi
  printf '%s\n' "Checkpoint cleanup: ${CHECKPOINT_CLEANUP_MODE}"
  printf '%s\n' "Restore attempts: ${RESTORE_MAX_ATTEMPTS} maximum from the same checkpoint"
fi
printf '%s\n' "DMTCP signal: ${DMTCP_SIGCKPT}"
printf '%s\n' "============================================================"

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# Baseline execution
# ---------------------------------------------------------------------------
if [ "${SCENARIO}" = "baseline" ]; then
  phase baseline "Launching ${BENCHMARK^^}.${NPB_CLASS} with ${NP} MPI ranks."
  TOTAL_START_NS="$(now_ns)"

  mpirun -np "${NP}" "${NPB_BIN}" > stdout.log 2> stderr.log &
  APP_PID=$!
  monitor_background_process "${APP_PID}" baseline "${TOTAL_START_NS}" "${PROGRESS_INTERVAL_SECONDS}"

  set +e
  wait "${APP_PID}"
  APP_STATUS=$?
  set -e
  APP_PID=""

  TOTAL_END_NS="$(now_ns)"
  write_elapsed total_seconds.txt "${TOTAL_START_NS}" "${TOTAL_END_NS}"

  if [ "${APP_STATUS}" -ne 0 ]; then
    echo "FAILED" > run_status.txt
    collect_diagnostics baseline_failed
    fail "baseline MPI execution failed with status ${APP_STATUS}."
  fi

  if ! verify_npb_output stdout.log; then
    echo "FAILED" > run_status.txt
    collect_diagnostics baseline_verification_failed
    fail "NPB did not report Verification = SUCCESSFUL."
  fi

  echo "1" > npb_verification_successful.txt
  cp total_seconds.txt baseline_reference_seconds.txt
  write_execution_summary
  echo "SUCCESS" > run_status.txt
  mark_success

  phase baseline "Completed successfully in $(human_seconds "$(<total_seconds.txt)")."
  echo
  cat execution_summary.txt

  cleanup
  trap - EXIT INT TERM
  exit 0
fi

# ---------------------------------------------------------------------------
# Checkpoint/restart execution: preserve the validated single-node runner order.
# ---------------------------------------------------------------------------
PORT="${DMTCP_COORD_PORT:-$(select_random_port)}"
echo "${PORT}" > dmtcp_coord_port.txt
echo "DMTCP port: ${PORT}" >> run_metadata.txt

phase coordinator "Starting a fresh DMTCP coordinator on port ${PORT} with --exit-on-last."
dmtcp_coordinator --coord-port "${PORT}" --exit-on-last -q \
  > coordinator.log 2>&1 &
COORD_PID=$!

if ! wait_for_coordinator; then
  echo "FAILED" > run_status.txt
  collect_diagnostics coordinator_start_failed
  fail "DMTCP coordinator did not become ready."
fi
phase coordinator "Coordinator is ready."

TOTAL_START_NS="$(now_ns)"
phase run "Launching ${BENCHMARK^^}.${NPB_CLASS} with ${NP} MPI ranks under DMTCP."
dmtcp_launch --coord-port "${PORT}" \
  mpirun -np "${NP}" "${NPB_BIN}" \
  > stdout_before_ckpt.log 2> stderr_before_ckpt.log &
APP_PID=$!

phase run "Waiting until the checkpoint target at ${CHECKPOINT_DELAY_SECONDS} seconds after launch."
if ! wait_until_checkpoint_target "${APP_PID}" "${CHECKPOINT_DELAY_SECONDS}" "${TOTAL_START_NS}"; then
  echo "FAILED" > run_status.txt
  collect_diagnostics application_finished_before_checkpoint
  fail "application finished before the checkpoint target."
fi

PRE_CKPT_END_NS="$(now_ns)"
write_elapsed pre_checkpoint_runtime_seconds.txt "${TOTAL_START_NS}" "${PRE_CKPT_END_NS}"

BEFORE_LIST="$(dmtcp_list)"
printf '%s\n' "${BEFORE_LIST}" > dmtcp_list_before_checkpoint.txt
DETECTED_CLIENTS="$(count_regex "${BEFORE_LIST}" 'WorkerState::')"

if [ "${DETECTED_CLIENTS}" -le 0 ]; then
  echo "FAILED" > run_status.txt
  collect_diagnostics no_clients_before_checkpoint
  fail "no DMTCP clients were detected before checkpointing."
fi
EXPECTED_DMTCP_CLIENTS="${DETECTED_CLIENTS}"
echo "${EXPECTED_DMTCP_CLIENTS}" > dmtcp_clients_before_checkpoint.txt
phase checkpoint "Detected ${EXPECTED_DMTCP_CLIENTS} DMTCP clients; creating checkpoint images now."

CKPT_START_NS="$(now_ns)"
CKPT_COMMAND_START_NS="${CKPT_START_NS}"
if ! dmtcp_command --coord-port "${PORT}" --checkpoint; then
  CKPT_COMMAND_END_NS="$(now_ns)"
  write_elapsed checkpoint_command_seconds.txt "${CKPT_COMMAND_START_NS}" "${CKPT_COMMAND_END_NS}"
  echo "FAILED" > run_status.txt
  collect_diagnostics checkpoint_command_failed
  fail "DMTCP checkpoint command failed."
fi
CKPT_COMMAND_END_NS="$(now_ns)"
write_elapsed checkpoint_command_seconds.txt "${CKPT_COMMAND_START_NS}" "${CKPT_COMMAND_END_NS}"

CKPT_WAIT_START_NS="$(now_ns)"
CKPT_DEADLINE=$((SECONDS + CHECKPOINT_FILE_TIMEOUT_SECONDS))
LAST_CKPT_REPORT=-1
RESTART_SCRIPT=""

while true; do
  CKPT_COUNT="$(find . -maxdepth 1 -type f -name 'ckpt_*.dmtcp' | wc -l)"
  RESTART_SCRIPT="$(find . -maxdepth 1 -type f -name 'dmtcp_restart_script*.sh' -print -quit)"

  if [ "${CKPT_COUNT}" -ge "${EXPECTED_DMTCP_CLIENTS}" ] && [ -n "${RESTART_SCRIPT}" ]; then
    break
  fi

  if [ "${CKPT_COUNT}" -ne "${LAST_CKPT_REPORT}" ]; then
    phase checkpoint "Checkpoint progress: ${CKPT_COUNT}/${EXPECTED_DMTCP_CLIENTS} images; restart script $([ -n "${RESTART_SCRIPT}" ] && echo present || echo pending)."
    LAST_CKPT_REPORT="${CKPT_COUNT}"
  fi

  if [ "${SECONDS}" -ge "${CKPT_DEADLINE}" ]; then
    CKPT_WAIT_END_NS="$(now_ns)"
    write_elapsed checkpoint_file_wait_seconds.txt "${CKPT_WAIT_START_NS}" "${CKPT_WAIT_END_NS}"
    echo "FAILED" > run_status.txt
    collect_diagnostics checkpoint_file_timeout
    fail "timed out waiting for ${EXPECTED_DMTCP_CLIENTS} checkpoint images and the restart script."
  fi
  sleep 0.2
done

CKPT_END_NS="$(now_ns)"
CKPT_WAIT_END_NS="${CKPT_END_NS}"
write_elapsed checkpoint_file_wait_seconds.txt "${CKPT_WAIT_START_NS}" "${CKPT_WAIT_END_NS}"
write_elapsed checkpoint_seconds.txt "${CKPT_START_NS}" "${CKPT_END_NS}"
echo "${CKPT_COUNT}" > checkpoint_image_count.txt
checkpoint_storage_metrics

RESTART_SCRIPT_ABS="$(readlink -f "${RESTART_SCRIPT}")"
phase checkpoint "Checkpoint recorded successfully at ${RUN_DIR} (took $(human_seconds "$(<checkpoint_seconds.txt)"))."
phase checkpoint "Created ${CKPT_COUNT} checkpoint images; restart script: ${RESTART_SCRIPT_ABS}."
phase checkpoint "Checkpoint storage: $(printf '%.6f' "$(<checkpoint_size_gb.txt)") GB total | $(printf '%.6f' "$(<checkpoint_mean_per_rank_gb.txt)") GB mean per application rank."

STABILIZE_START_NS="$(now_ns)"
if python3 - "${POST_CHECKPOINT_STABILIZATION_SECONDS}" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) > 0 else 1)
PY
then
  phase checkpoint "Allowing ${POST_CHECKPOINT_STABILIZATION_SECONDS} seconds for post-checkpoint stabilization."
  sleep "${POST_CHECKPOINT_STABILIZATION_SECONDS}"
fi
STABILIZE_END_NS="$(now_ns)"
write_elapsed post_checkpoint_stabilization_seconds.txt "${STABILIZE_START_NS}" "${STABILIZE_END_NS}"

if ! pid_is_active "${APP_PID}"; then
  echo "FAILED" > run_status.txt
  collect_diagnostics original_application_died_after_checkpoint
  fail "original application exited unexpectedly immediately after checkpoint creation."
fi

CLEANUP_STATE="${RUN_DIR}/pre_restore_captured_state.json"
phase cleanup "Capturing the exact original process tree and its TCP, UDP, and Unix socket endpoints."
if ! python3 "${ADAPTIVE_CLEANUP_HELPER}" capture \
  --root-pid "${APP_PID}" \
  --root-pid "${COORD_PID}" \
  --state "${CLEANUP_STATE}" \
  --process-report "${RUN_DIR}/pre_restore_captured_processes.tsv" \
  --socket-report "${RUN_DIR}/pre_restore_captured_sockets.tsv" \
  > pre_restore_capture.log 2>&1; then
  echo "FAILED" > run_status.txt
  collect_diagnostics pre_restore_capture_failed
  fail "could not capture the original process tree and socket endpoints before shutdown."
fi
cat pre_restore_capture.log

phase shutdown "Stopping the original checkpointed computation."
phase shutdown "Requesting DMTCP client termination on port ${PORT}; the --exit-on-last coordinator must also exit."
dmtcp_command --coord-port "${PORT}" --kill >/dev/null 2>&1 || true

phase cleanup "Waiting adaptively for captured processes and endpoints to become safely reusable."
set +e
python3 "${ADAPTIVE_CLEANUP_HELPER}" cleanup \
  --state "${CLEANUP_STATE}" \
  --metrics-dir "${RUN_DIR}" \
  --timeout "${PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS}" \
  --poll "${PRE_RESTORE_CLEANUP_POLL_SECONDS}" \
  --force-kill-after "${PRE_RESTORE_FORCE_KILL_AFTER_SECONDS}" \
  --force-kill-grace "${PRE_RESTORE_FORCE_KILL_GRACE_SECONDS}" \
  --final-grace "${PRE_RESTORE_FINAL_GRACE_SECONDS}" \
  --report-interval "${PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS}" \
  > pre_restore_cleanup.log 2>&1
CLEANUP_STATUS=$?
set -e
cat pre_restore_cleanup.log

# Reap the two direct children after the helper has verified their captured
# PID/start-time identities are no longer active. These waits cannot target a
# reused PID because the shell waits for its own original child objects.
set +e
wait "${APP_PID}"
APP_STATUS=$?
wait "${COORD_PID}"
COORD_STATUS=$?
set -e
APP_PID=""
COORD_PID=""

if [ "${CLEANUP_STATUS}" -ne 0 ]; then
  echo "FAILED" > run_status.txt
  collect_diagnostics pre_restore_cleanup_failed
  fail "adaptive pre-restore cleanup failed with status ${CLEANUP_STATUS}; restore was not launched."
fi

phase cleanup "Adaptive pre-restore cleanup completed in $(human_seconds "$(<pre_restore_cleanup_seconds.txt)")."

[ -n "${RESTART_SCRIPT}" ] && [ -f "${RESTART_SCRIPT}" ] \
  || fail "restart script disappeared before restore."
chmod +x "${RESTART_SCRIPT}"

RESTORE_START_NS="$(now_ns)"
reserve_restore_ports
phase restore "Restoring checkpoints using script: ${RESTART_SCRIPT_ABS}"
phase restore "The generated script will launch a new coordinator and restore ${EXPECTED_DMTCP_CLIENTS} DMTCP clients."
phase restore "Up to ${RESTORE_MAX_ATTEMPTS} attempts will reuse this same checkpoint if a restore attempt stalls or exits before RUNNING."

mkdir -p restore_attempts
printf 'attempt\tstatus\tduration_seconds\treason\n' > restore_attempts_summary.tsv
RESTORE_FOUND=0
SUCCESSFUL_RESTORE_ATTEMPT=0
RESTORE_ATTEMPTS_EXECUTED=0
ATTEMPT_FAILURE_KIND=""
ATTEMPT_FAILURE_MESSAGE=""

for (( RESTORE_ATTEMPT=1; RESTORE_ATTEMPT<=RESTORE_MAX_ATTEMPTS; RESTORE_ATTEMPT++ )); do
  ATTEMPT_DIR="restore_attempts/attempt_$(printf '%02d' "${RESTORE_ATTEMPT}")"
  RESTORE_ATTEMPTS_EXECUTED="${RESTORE_ATTEMPT}"

  if run_restore_attempt "${RESTORE_ATTEMPT}" "${ATTEMPT_DIR}"; then
    SUCCESSFUL_RESTORE_ATTEMPT="${RESTORE_ATTEMPT}"
    break
  fi

  phase restore "Attempt ${RESTORE_ATTEMPT}/${RESTORE_MAX_ATTEMPTS} failed: ${ATTEMPT_FAILURE_MESSAGE}."

  if ! cleanup_failed_restore_attempt "${RESTORE_ATTEMPT}" "${ATTEMPT_DIR}"; then
    echo "0" > dmtcp_restore_marker_found.txt
    echo "FAILED" > run_status.txt
    fail "failed restore attempt ${RESTORE_ATTEMPT} could not be cleaned safely; no further attempt was launched."
  fi

  if [ "${RESTORE_ATTEMPT}" -lt "${RESTORE_MAX_ATTEMPTS}" ]; then
    CURRENT_CKPT_COUNT="$(find . -maxdepth 1 -type f -name 'ckpt_*.dmtcp' | wc -l)"
    if [ "${CURRENT_CKPT_COUNT}" -lt "${EXPECTED_DMTCP_CLIENTS}" ] || \
       [ ! -f "${RESTART_SCRIPT}" ]; then
      echo "0" > dmtcp_restore_marker_found.txt
      echo "FAILED" > run_status.txt
      fail "checkpoint artifacts are incomplete after failed restore attempt ${RESTORE_ATTEMPT}; retry is unsafe."
    fi
    echo "RETRYING_RESTORE" > run_status.txt
    phase restore "Retrying from the same ${CURRENT_CKPT_COUNT} checkpoint images after verified cleanup."
  fi
done

printf '%s\n' "${SUCCESSFUL_RESTORE_ATTEMPT}" > restore_attempt_count.txt
printf '%s\n' "$((SUCCESSFUL_RESTORE_ATTEMPT > 0 ? SUCCESSFUL_RESTORE_ATTEMPT - 1 : RESTORE_MAX_ATTEMPTS - 1))" \
  > restore_retry_count.txt

if [ "${RESTORE_FOUND}" -ne 1 ] || [ "${SUCCESSFUL_RESTORE_ATTEMPT}" -le 0 ]; then
  echo "0" > dmtcp_restore_marker_found.txt
  echo "FAILED" > run_status.txt
  fail "all ${RESTORE_MAX_ATTEMPTS} restore attempts failed; checkpoint images and per-attempt diagnostics were preserved."
fi

if ! release_restore_ports; then
  echo "FAILED" > run_status.txt
  fail "restore succeeded, but the previous reserved-port setting could not be restored safely."
fi

RESTORE_END_NS="$(now_ns)"
write_elapsed dmtcp_restore_seconds.txt "${RESTORE_START_NS}" "${RESTORE_END_NS}"
SUCCESSFUL_ATTEMPT_DIR="restore_attempts/attempt_$(printf '%02d' "${SUCCESSFUL_RESTORE_ATTEMPT}")"
cp -f -- \
  "${SUCCESSFUL_ATTEMPT_DIR}/duration_seconds.txt" \
  successful_restore_attempt_seconds.txt

echo "1" > dmtcp_restore_marker_found.txt
echo "${RUNNING_AFTER_RESTORE}" > dmtcp_clients_running_after_restore.txt
phase restore "Restore complete on attempt ${SUCCESSFUL_RESTORE_ATTEMPT}/${RESTORE_MAX_ATTEMPTS}: ${RUNNING_AFTER_RESTORE}/${EXPECTED_DMTCP_CLIENTS} DMTCP clients are RUNNING."
phase restore "Successful attempt took $(human_seconds "$(<successful_restore_attempt_seconds.txt)"); total restore phase including failed attempts and retry cleanup took $(human_seconds "$(<dmtcp_restore_seconds.txt)")."
phase run "Restored ${BENCHMARK^^}.${NPB_CLASS} computation is continuing."

POST_RESTORE_START_NS="${RESTORE_END_NS}"
monitor_background_process \
  "${RESTORED_PID}" \
  run \
  "${POST_RESTORE_START_NS}" \
  "${PROGRESS_INTERVAL_SECONDS}" \
  "${TOTAL_START_NS}"

set +e
wait "${RESTORED_PID}"
RESTORED_STATUS=$?
set -e

# The first canonical-log copy was taken when every DMTCP client reached
# RUNNING. Refresh it after the restored application exits so NPB verification,
# timing, and final benchmark output are read from the complete attempt logs.
copy_restore_attempt_to_canonical_logs "${SUCCESSFUL_ATTEMPT_DIR}"

RESTORED_PID=""
RESTORE_COMPLETION_NS="$(now_ns)"
write_elapsed post_dmtcp_restore_runtime_seconds.txt "${POST_RESTORE_START_NS}" "${RESTORE_COMPLETION_NS}"

if [ "${RESTORED_STATUS}" -ne 0 ]; then
  echo "FAILED" > run_status.txt
  collect_diagnostics restored_application_failed
  fail "restored execution exited with status ${RESTORED_STATUS}."
fi

TOTAL_END_NS="$(now_ns)"
write_elapsed total_seconds.txt "${TOTAL_START_NS}" "${TOTAL_END_NS}"

if ! verify_npb_output stdout_before_ckpt.log stdout_after_restore.log; then
  echo "0" > npb_verification_successful.txt
  echo "FAILED" > run_status.txt
  collect_diagnostics npb_verification_failed
  fail "restored NPB execution did not report Verification = SUCCESSFUL."
fi

echo "1" > npb_verification_successful.txt
write_overhead_metrics "$(<total_seconds.txt)"
write_checkpoint_restore_overhead_metrics
write_execution_summary
delete_checkpoint_artifacts
echo "SUCCESS" > run_status.txt
mark_success

phase complete "NPB verification was SUCCESSFUL."
phase complete "All metrics were written to ${RUN_DIR}."
echo
cat execution_summary.txt

cleanup
trap - EXIT INT TERM
exit 0
