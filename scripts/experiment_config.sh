#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

# Shared configuration for the NPB/DMTCP experiment suite.
#
# List-valued matrix fields are populated from space-separated text variables,
# while repetition settings are positive integer counts:
#
#   MPI_RANKS_TEXT="4 9 16" ./scripts/build_npb_bt_cg_d.sh
#   BASELINE_REPETITIONS=3 CR_REPETITIONS=3 ./scripts/run_all.sh
#
# REPETITIONS remains a shorthand that sets both repetition counts when the
# baseline and checkpoint/restart counts should be identical.

CONFIG_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${CONFIG_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Generated artifacts
# ---------------------------------------------------------------------------
#
# By default, no generated files are stored inside scripts/.
#
# Repository-local default:
#
#   <repository>/output/
#   ├── binaries/
#   └── results/
#
# OUTPUT_ROOT is the recommended single override:
#
#   OUTPUT_ROOT=/mnt/fast/npb-dmtcp-output ./scripts/run_all.sh
#
# BINARY_ROOT and RESULTS_ROOT can also be overridden independently.

OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/output}"
BINARY_ROOT="${BINARY_ROOT:-${OUTPUT_ROOT}/binaries}"
RESULTS_ROOT="${RESULTS_ROOT:-${OUTPUT_ROOT}/results}"

# ---------------------------------------------------------------------------
# Installation paths
# ---------------------------------------------------------------------------

ENV_FILE="${ENV_FILE:-${HOME}/opt/enable_dmtcp_mpich_env.sh}"
NPB_ROOT="${NPB_ROOT:-${HOME}/NPB3.4-MPI}"
NPB_CLASS="${NPB_CLASS:-D}"

# ---------------------------------------------------------------------------
# Required DMTCP/MPICH stack
# ---------------------------------------------------------------------------

# Exact single-node stack preserved from the previously working package.
WORKING_DMTCP_COMMIT="${WORKING_DMTCP_COMMIT:-6896e12276a9fe449edb0cf206203ce01b19efe6}"
WORKING_DMTCP_RESTORE_LISTEN_BACKLOG="${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG:-1024}"
WORKING_DMTCP_RESTORE_LISTENER_PATHS="${WORKING_DMTCP_RESTORE_LISTENER_PATHS:-4}"
WORKING_DMTCP_KERNELBUFFERDRAINER_SHA256="${WORKING_DMTCP_KERNELBUFFERDRAINER_SHA256:-c5d7b960220762b6a291f5a1aef5989786ed47c00318dcc78a8fb2b6db9cf04c}"
WORKING_MPICH_VERSION="${WORKING_MPICH_VERSION:-5.0.0}"
WORKING_MPICH_DEVICE="${WORKING_MPICH_DEVICE:-ch3:nemesis}"

# Refuse to run experiments with a different stack by default. This prevents a
# helper script or shell configuration from silently selecting another DMTCP
# revision or a differently configured MPICH installation.
#
# Set REQUIRE_WORKING_STACK=false only for deliberate comparison tests.
REQUIRE_WORKING_STACK="${REQUIRE_WORKING_STACK:-true}"

# ---------------------------------------------------------------------------
# Experiment matrix
# ---------------------------------------------------------------------------

BENCHMARKS_TEXT="${BENCHMARKS_TEXT:-bt cg}"
MPI_RANKS_TEXT="${MPI_RANKS_TEXT:-4}"
BASELINE_REPETITIONS="${BASELINE_REPETITIONS:-${REPETITIONS:-3}}"
CR_REPETITIONS="${CR_REPETITIONS:-${REPETITIONS:-3}}"
CHECKPOINT_PERCENTAGES_TEXT="${CHECKPOINT_PERCENTAGES_TEXT:-25 50 75}"

read -r -a BENCHMARKS <<< "${BENCHMARKS_TEXT}"
read -r -a MPI_RANKS <<< "${MPI_RANKS_TEXT}"
read -r -a CHECKPOINT_PERCENTAGES <<< "${CHECKPOINT_PERCENTAGES_TEXT}"

# ---------------------------------------------------------------------------
# Baseline execution
# ---------------------------------------------------------------------------

# Baselines are included in the matrix by default because their mean determines
# percentage-based checkpoint targets. With EXISTING_RUN_POLICY=resume,
# successful baseline repetitions are skipped by SUCCESS.marker.
#
# Set RUN_BASELINE=false only when all requested baseline result directories
# already contain SUCCESS.marker and valid total_seconds.txt files.
RUN_BASELINE="${RUN_BASELINE:-true}"

# ---------------------------------------------------------------------------
# Existing run directories
# ---------------------------------------------------------------------------
#
# resume:
#   Skip runs containing SUCCESS.marker and replace incomplete run directories.
#
# replace:
#   Remove and rerun every requested experiment.
#
# error:
#   Stop when any requested run directory already exists.

EXISTING_RUN_POLICY="${EXISTING_RUN_POLICY:-resume}"

# Checkpoint storage is measured before this cleanup policy is applied.
#
# Supported values:
#   delete-checkpoints
#   keep-checkpoints
CHECKPOINT_CLEANUP_MODE="${CHECKPOINT_CLEANUP_MODE:-delete-checkpoints}"

# ---------------------------------------------------------------------------
# Coordinator and restart behavior
# ---------------------------------------------------------------------------

# The runner uses the validated single-node sequence:
#
#   1. Start a fresh coordinator with --exit-on-last.
#   2. Launch the MPI application through dmtcp_launch.
#   3. Create and validate the checkpoint images.
#   4. Capture the exact original process tree and its socket endpoints.
#   5. Kill the original DMTCP computation and allow its coordinator to exit.
#   6. Adaptively wait for the captured processes and endpoints to become clear.
#   7. Execute the generated restart script without extra arguments.
#
# This value is intentionally fixed for the validated single-node workflow.
COORDINATOR_LIFECYCLE="fresh"

# The runner selects a random high port and verifies
# that the selected port is free before starting the coordinator.
#
# A specific port can still be forced with:
#
#   DMTCP_COORD_PORT=29977 ./scripts/run_one.sh ...
DMTCP_PORT_MIN="${DMTCP_PORT_MIN:-20000}"
DMTCP_PORT_MAX="${DMTCP_PORT_MAX:-39999}"

# The validated configuration uses signal 30.
#
# Override only for controlled comparison experiments:
#
#   DMTCP_EXPERIMENT_SIGNAL=12 ./scripts/run_one.sh ...
DMTCP_EXPERIMENT_SIGNAL="${DMTCP_EXPERIMENT_SIGNAL:-30}"

# ---------------------------------------------------------------------------
# Timeouts, delays, and progress reporting
# ---------------------------------------------------------------------------

COORDINATOR_START_TIMEOUT_SECONDS="${COORDINATOR_START_TIMEOUT_SECONDS:-30}"
CHECKPOINT_FILE_TIMEOUT_SECONDS="${CHECKPOINT_FILE_TIMEOUT_SECONDS:-600}"
DMTCP_RESTORE_TIMEOUT_SECONDS="${DMTCP_RESTORE_TIMEOUT_SECONDS:-600}"

# A restore attempt can occasionally stall because of a timing-sensitive DMTCP
# socket-restart race. Retry the same validated checkpoint instead of creating a
# new checkpoint. The value is the total number of attempts, including the
# first attempt.
RESTORE_MAX_ATTEMPTS="${RESTORE_MAX_ATTEMPTS:-3}"

# After a failed restore attempt, the captured failed process tree and its
# endpoints are cleaned with adaptive_pre_restore_cleanup.py. This grace is
# applied only after all captured endpoints are verified reusable.
RESTORE_RETRY_FINAL_GRACE_SECONDS="${RESTORE_RETRY_FINAL_GRACE_SECONDS:-10}"

# Prevent DMTCP's temporary IPv4 restore listener (bind(port=0)) from being
# assigned a captured original application listener port. The runner holds a
# suite-wide lock, adds captured IPv4 TCP LISTEN ports to
# net.ipv4.ip_local_reserved_ports for the complete restore-attempt sequence,
# and restores the previous value afterward.
RESTORE_RESERVE_ORIGINAL_TCP_PORTS="${RESTORE_RESERVE_ORIGINAL_TCP_PORTS:-true}"
RESTORE_PORT_RESERVATION_LOCK_FILE="${RESTORE_PORT_RESERVATION_LOCK_FILE:-/run/lock/npb_dmtcp_restore_ports.lock}"
RESTORE_PORT_RESERVATION_LOCK_TIMEOUT_SECONDS="${RESTORE_PORT_RESERVATION_LOCK_TIMEOUT_SECONDS:-30}"
RESTORE_IP_LOCAL_RESERVED_PORTS_PATH="${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH:-/proc/sys/net/ipv4/ip_local_reserved_ports}"

POST_CHECKPOINT_STABILIZATION_SECONDS="${POST_CHECKPOINT_STABILIZATION_SECONDS:-2}"

# Complete adaptive cleanup timeout, including exact-process shutdown, endpoint
# verification, removal of provably stale filesystem Unix sockets, and the
# final verified-clear grace delay.
PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS="${PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS:-180}"
PRE_RESTORE_CLEANUP_POLL_SECONDS="${PRE_RESTORE_CLEANUP_POLL_SECONDS:-0.25}"

# dmtcp_command --kill is attempted first. TERM is sent only to captured
# PID/start-time identities that remain after this delay; KILL follows only for
# those same surviving identities after the configured grace period.
PRE_RESTORE_FORCE_KILL_AFTER_SECONDS="${PRE_RESTORE_FORCE_KILL_AFTER_SECONDS:-10}"
PRE_RESTORE_FORCE_KILL_GRACE_SECONDS="${PRE_RESTORE_FORCE_KILL_GRACE_SECONDS:-5}"

# Applied only after every captured TCP, UDP, and Unix endpoint has been
# verified reusable. This replaces the previous unconditional cleanup delay.
PRE_RESTORE_FINAL_GRACE_SECONDS="${PRE_RESTORE_FINAL_GRACE_SECONDS:-2}"
PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS="${PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS:-5}"

# During restore, persistent bind errors cause an early diagnostic failure
# instead of consuming the complete DMTCP_RESTORE_TIMEOUT_SECONDS interval.
RESTORE_BIND_FAILURE_ABORT_SECONDS="${RESTORE_BIND_FAILURE_ABORT_SECONDS:-10}"

PROGRESS_INTERVAL_SECONDS="${PROGRESS_INTERVAL_SECONDS:-30}"
RESTORE_PROGRESS_INTERVAL_SECONDS="${RESTORE_PROGRESS_INTERVAL_SECONDS:-5}"

# ---------------------------------------------------------------------------
# Working-stack verification
# ---------------------------------------------------------------------------

verify_single_node_stack() {
  local command_name
  local executable
  local expected_root
  local kernel_somaxconn
  local required_variable
  local dmtcp_ipc_plugin
  local dmtcp_ipc_plugin_sha256

  case "${REQUIRE_WORKING_STACK}" in
    true)
      ;;
    false)
      echo "WARNING: Exact working-stack verification is disabled." >&2
      return 0
      ;;
    *)
      echo "ERROR: REQUIRE_WORKING_STACK must be true or false." >&2
      return 1
      ;;
  esac

  if [ "${DMTCP_SINGLE_NODE_PROFILE:-}" != "1" ]; then
    echo "ERROR: The active environment was not generated by the" >&2
    echo "single-node DMTCP/MPICH installer." >&2
    echo >&2
    echo "Source the environment file first:" >&2
    echo "  source ${ENV_FILE}" >&2
    echo >&2
    echo "If the file does not exist, run:" >&2
    echo "  ./scripts/install_dmtcp_mpich_env.sh" >&2
    return 1
  fi

  if [ "${DMTCP_COMMIT:-}" != "${WORKING_DMTCP_COMMIT}" ]; then
    echo "ERROR: Unexpected DMTCP commit." >&2
    echo "  Required: ${WORKING_DMTCP_COMMIT}" >&2
    echo "  Active:   ${DMTCP_COMMIT:-unset}" >&2
    return 1
  fi

  if [ "${DMTCP_RESTORE_BACKLOG_PATCH:-}" != "1" ] || \
     [ "${DMTCP_RESTORE_LISTEN_BACKLOG:-}" != "${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}" ] || \
     [ "${DMTCP_RESTORE_LISTENER_PATHS:-}" != "${WORKING_DMTCP_RESTORE_LISTENER_PATHS}" ]; then
    echo "ERROR: The active DMTCP installation does not contain the" >&2
    echo "required restore-listener backlog patch." >&2
    echo "  Required backlog: ${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}" >&2
    echo "  Active backlog:   ${DMTCP_RESTORE_LISTEN_BACKLOG:-unset}" >&2
    echo "  Required listener paths: ${WORKING_DMTCP_RESTORE_LISTENER_PATHS}" >&2
    echo "  Active listener paths:   ${DMTCP_RESTORE_LISTENER_PATHS:-unset}" >&2
    echo "Rebuild DMTCP with install_dmtcp_mpich_env.sh." >&2
    return 1
  fi

  if ! grep -Fxq \
      "dmtcp_restore_listen_backlog=${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}" \
      "${DMTCP_MPICH_MANIFEST:-/nonexistent}" 2>/dev/null || \
     ! grep -Fxq \
      "dmtcp_restore_listener_paths=${WORKING_DMTCP_RESTORE_LISTENER_PATHS}" \
      "${DMTCP_MPICH_MANIFEST:-/nonexistent}" 2>/dev/null; then
    echo "ERROR: The build manifest does not verify the required" >&2
    echo "DMTCP restore-listener backlog patch." >&2
    return 1
  fi

  dmtcp_ipc_plugin="$(
    find -L "${DMTCP_HOME:-/nonexistent}" \
      -type f \
      -path '*/lib/dmtcp/libdmtcp_ipc.so' \
      -print -quit 2>/dev/null || true
  )"
  if [ -z "${dmtcp_ipc_plugin}" ]; then
    echo "ERROR: The active DMTCP IPC plugin was not found." >&2
    echo "  DMTCP_HOME: ${DMTCP_HOME:-unset}" >&2
    return 1
  fi

  if ! grep -aFq 'stream-refill header receive failed' "${dmtcp_ipc_plugin}" || \
     ! grep -aFq 'stream-refill payload send failed' "${dmtcp_ipc_plugin}"; then
    echo "ERROR: The active DMTCP IPC plugin does not contain the" >&2
    echo "nonblocking duplex stream-refill fix." >&2
    echo "  Plugin: ${dmtcp_ipc_plugin}" >&2
    echo "Rebuild DMTCP with install_dmtcp_mpich_env.sh." >&2
    return 1
  fi

  if [ -n "${DMTCP_DUPLEX_REFILL_PATCH:-}" ] && \
     [ "${DMTCP_DUPLEX_REFILL_PATCH}" != "1" ]; then
    echo "ERROR: The environment helper reports that the DMTCP duplex" >&2
    echo "stream-refill patch is inactive." >&2
    return 1
  fi

  if [ -n "${DMTCP_KERNELBUFFERDRAINER_SHA256:-}" ] && \
     [ "${DMTCP_KERNELBUFFERDRAINER_SHA256}" != \
       "${WORKING_DMTCP_KERNELBUFFERDRAINER_SHA256}" ]; then
    echo "ERROR: Unexpected patched kernelbufferdrainer.cpp checksum." >&2
    echo "  Required: ${WORKING_DMTCP_KERNELBUFFERDRAINER_SHA256}" >&2
    echo "  Active:   ${DMTCP_KERNELBUFFERDRAINER_SHA256}" >&2
    return 1
  fi

  dmtcp_ipc_plugin_sha256="$(sha256sum "${dmtcp_ipc_plugin}" | awk '{print $1}')"
  if [ -n "${DMTCP_IPC_PLUGIN_SHA256:-}" ] && \
     [ "${DMTCP_IPC_PLUGIN_SHA256}" != "${dmtcp_ipc_plugin_sha256}" ]; then
    echo "ERROR: The active DMTCP IPC plugin differs from the environment" >&2
    echo "helper metadata." >&2
    echo "  Expected: ${DMTCP_IPC_PLUGIN_SHA256}" >&2
    echo "  Actual:   ${dmtcp_ipc_plugin_sha256}" >&2
    return 1
  fi

  DMTCP_DUPLEX_REFILL_PATCH_ACTIVE=1
  DMTCP_IPC_PLUGIN_PATH="${dmtcp_ipc_plugin}"
  DMTCP_IPC_PLUGIN_SHA256="${dmtcp_ipc_plugin_sha256}"
  export DMTCP_DUPLEX_REFILL_PATCH_ACTIVE
  export DMTCP_IPC_PLUGIN_PATH
  export DMTCP_IPC_PLUGIN_SHA256

  kernel_somaxconn="$(cat /proc/sys/net/core/somaxconn 2>/dev/null || true)"
  if ! [[ "${kernel_somaxconn}" =~ ^[0-9]+$ ]] || \
     [ "${kernel_somaxconn}" -lt "${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}" ]; then
    echo "ERROR: net.core.somaxconn is smaller than the DMTCP" >&2
    echo "restore-listener backlog." >&2
    echo "  Required minimum: ${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}" >&2
    echo "  Active value:     ${kernel_somaxconn:-unreadable}" >&2
    return 1
  fi

  if [ "${MPICH_VERSION:-}" != "${WORKING_MPICH_VERSION}" ]; then
    echo "ERROR: Unexpected MPICH version." >&2
    echo "  Required: ${WORKING_MPICH_VERSION}" >&2
    echo "  Active:   ${MPICH_VERSION:-unset}" >&2
    return 1
  fi

  if [ "${MPICH_DEVICE:-}" != "${WORKING_MPICH_DEVICE}" ]; then
    echo "ERROR: Unexpected MPICH device." >&2
    echo "  Required: ${WORKING_MPICH_DEVICE}" >&2
    echo "  Active:   ${MPICH_DEVICE:-unset}" >&2
    return 1
  fi

  if [ "${MPICH_HWLOC_LIBUDEV:-}" != "disabled" ]; then
    echo "ERROR: MPICH embedded hwloc was not verified with" >&2
    echo "libudev disabled." >&2
    echo "Rebuild MPICH with the single-node installer." >&2
    return 1
  fi

  if [ ! -r "${DMTCP_MPICH_MANIFEST:-}" ]; then
    echo "ERROR: Working-stack manifest is missing or unreadable:" >&2
    echo "  ${DMTCP_MPICH_MANIFEST:-unset}" >&2
    return 1
  fi

  for required_variable in DMTCP_HOME MPICH_HOME; do
    if [ -z "${!required_variable:-}" ]; then
      echo "ERROR: Required environment variable is unset:" >&2
      echo "  ${required_variable}" >&2
      echo >&2
      echo "Source the environment file:" >&2
      echo "  source ${ENV_FILE}" >&2
      return 1
    fi
  done

  if [ ! -d "${DMTCP_HOME}" ]; then
    echo "ERROR: DMTCP_HOME does not identify a directory:" >&2
    echo "  ${DMTCP_HOME}" >&2
    return 1
  fi

  if [ ! -d "${MPICH_HOME}" ]; then
    echo "ERROR: MPICH_HOME does not identify a directory:" >&2
    echo "  ${MPICH_HOME}" >&2
    return 1
  fi

  for command_name in \
    dmtcp_launch \
    dmtcp_command \
    dmtcp_coordinator \
    mpirun \
    mpicc \
    mpifort
  do
    executable="$(command -v "${command_name}" 2>/dev/null || true)"

    if [ -z "${executable}" ]; then
      echo "ERROR: Required command is unavailable: ${command_name}" >&2
      return 1
    fi

    executable="$(readlink -f "${executable}")"

    case "${command_name}" in
      dmtcp_*)
        expected_root="$(readlink -f "${DMTCP_HOME}")"
        ;;
      *)
        expected_root="$(readlink -f "${MPICH_HOME}")"
        ;;
    esac

    case "${executable}" in
      "${expected_root}"/*)
        ;;
      *)
        echo "ERROR: ${command_name} resolves outside the expected" >&2
        echo "installation." >&2
        echo "  Expected root: ${expected_root}" >&2
        echo "  Resolved:      ${executable}" >&2
        return 1
        ;;
    esac
  done

  for command_name in \
    gcc \
    gfortran \
    ldd \
    readelf \
    sha256sum
  do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "ERROR: Required build/runtime command is unavailable:" >&2
      echo "  ${command_name}" >&2
      return 1
    fi
  done

  return 0
}
