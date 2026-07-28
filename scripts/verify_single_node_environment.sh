#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=experiment_config.sh
source "${SCRIPT_DIR}/experiment_config.sh"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

if [ ! -f "${ENV_FILE}" ]; then
  fail "environment helper not found: ${ENV_FILE}"
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

verify_single_node_stack \
  || fail "the exact working single-node DMTCP/MPICH stack is not active."

python3 - <<'PY' \
  || fail "Python/Linux pidfd support is required for safe cleanup escalation."
import os
import signal
raise SystemExit(0 if hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal") else 1)
PY

command -v flock >/dev/null 2>&1 \
  || fail "flock is required for serialized restore-port reservation."

case "${RESTORE_RESERVE_ORIGINAL_TCP_PORTS}" in
  true|false) ;;
  *) fail "RESTORE_RESERVE_ORIGINAL_TCP_PORTS must be true or false." ;;
esac

if [ "${RESTORE_RESERVE_ORIGINAL_TCP_PORTS}" = "true" ]; then
  [ -r "${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH}" ] \
    || fail "cannot read ${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH}."
  [ -w "${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH}" ] \
    || fail "cannot write ${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH}; sufficient privilege is required for collision-safe restore-port reservation."
fi

read -r EPHEMERAL_PORT_MIN EPHEMERAL_PORT_MAX \
  < /proc/sys/net/ipv4/ip_local_port_range

[[ "${DMTCP_PORT_MIN}" =~ ^[0-9]+$ ]] \
  || fail "DMTCP_PORT_MIN must be an integer."
[[ "${DMTCP_PORT_MAX}" =~ ^[0-9]+$ ]] \
  || fail "DMTCP_PORT_MAX must be an integer."
[ "${DMTCP_PORT_MIN}" -ge 1024 ] && [ "${DMTCP_PORT_MAX}" -le 65535 ] && \
[ "${DMTCP_PORT_MIN}" -le "${DMTCP_PORT_MAX}" ] \
  || fail "invalid DMTCP random-port range: ${DMTCP_PORT_MIN}-${DMTCP_PORT_MAX}."

echo "============================================================"
echo "Single-node DMTCP/MPICH environment: VERIFIED"
echo "============================================================"
echo "DMTCP commit:          ${DMTCP_COMMIT}"
echo "DMTCP executable:      $(readlink -f "$(command -v dmtcp_launch)")"
echo "DMTCP restore backlog: ${DMTCP_RESTORE_LISTEN_BACKLOG} across ${DMTCP_RESTORE_LISTENER_PATHS} listener paths"
echo "DMTCP duplex refill:   ${DMTCP_DUPLEX_REFILL_PATCH_ACTIVE}"
echo "DMTCP receive capacity:${DMTCP_REFILL_RECEIVE_CAPACITY_PATCH_ACTIVE}"
echo "DMTCP IPC plugin:      ${DMTCP_IPC_PLUGIN_PATH}"
echo "DMTCP IPC SHA256:      ${DMTCP_IPC_PLUGIN_SHA256}"
echo "Kernel somaxconn:      $(cat /proc/sys/net/core/somaxconn)"
echo "MPICH version:         ${MPICH_VERSION}"
echo "MPICH device:          ${MPICH_DEVICE}"
echo "MPICH hwloc libudev:   ${MPICH_HWLOC_LIBUDEV}"
echo "MPIRun executable:     $(readlink -f "$(command -v mpirun)")"
echo "MPICH_NO_LOCAL:        ${MPICH_NO_LOCAL}"
echo "Helper DMTCP_SIGCKPT:  ${DMTCP_SIGCKPT}"
echo "Experiment signal:     ${DMTCP_EXPERIMENT_SIGNAL}"
echo "HWLOC_COMPONENTS:      ${HWLOC_COMPONENTS:-unset}"
echo "MPIR_CVAR_ENABLE_GPU:  ${MPIR_CVAR_ENABLE_GPU:-unset}"
echo "Coordinator lifecycle: ${COORDINATOR_LIFECYCLE}"
echo "Coordinator port range:${DMTCP_PORT_MIN}-${DMTCP_PORT_MAX}"
echo "Pre-restore cleanup:   timeout=${PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS}s, poll=${PRE_RESTORE_CLEANUP_POLL_SECONDS}s"
echo "Cleanup escalation:    TERM after ${PRE_RESTORE_FORCE_KILL_AFTER_SECONDS}s, KILL ${PRE_RESTORE_FORCE_KILL_GRACE_SECONDS}s later"
echo "Final verified grace:  ${PRE_RESTORE_FINAL_GRACE_SECONDS}s"
echo "Bind-failure abort:    ${RESTORE_BIND_FAILURE_ABORT_SECONDS}s persistent"
echo "Reserve restore ports: ${RESTORE_RESERVE_ORIGINAL_TCP_PORTS}"
echo "Reserved-ports sysctl: ${RESTORE_IP_LOCAL_RESERVED_PORTS_PATH}"
echo "Reservation lock:      ${RESTORE_PORT_RESERVATION_LOCK_FILE} (${RESTORE_PORT_RESERVATION_LOCK_TIMEOUT_SECONDS}s timeout)"
echo "PID-safe escalation:   Linux pidfd verified"
echo "Ephemeral port range:  ${EPHEMERAL_PORT_MIN}-${EPHEMERAL_PORT_MAX}"
echo "Kernel:                $(uname -srvo)"
echo "C library:             $(ldd --version 2>&1 | head -n 1)"
echo "GCC:                   $(gcc --version | head -n 1)"
echo "GFortran:              $(gfortran --version | head -n 1)"
echo

echo "DMTCP version output:"
dmtcp_launch --version
echo

echo "MPICH/Hydra build output:"
mpirun -version
echo

echo "Build manifest:"
cat "${DMTCP_MPICH_MANIFEST}"
echo

echo "Experiment binaries:"
found_binary=0
for benchmark in "${BENCHMARKS[@]}"; do
  binary="${BINARY_ROOT}/${benchmark}.${NPB_CLASS}.x"
  if [ ! -x "${binary}" ]; then
    echo "  MISSING: ${binary}"
    continue
  fi

  found_binary=1
  echo "  ${binary}"
  echo "    SHA256: $(sha256sum "${binary}" | awk '{print $1}')"

  mpi_linkage="$(ldd "${binary}" 2>/dev/null || true)"
  if printf "%s\n" "${mpi_linkage}" | grep -F "${MPICH_HOME}/" >/dev/null || \
     printf "%s\n" "${mpi_linkage}" | grep -F "$(readlink -f "${MPICH_HOME}")/" >/dev/null; then
    echo "    MPICH linkage: verified"
  else
    echo "    MPICH linkage: WRONG OR UNRESOLVED"
    echo "${mpi_linkage}" | sed 's/^/      /'
    fail "rebuild ${binary} with build_npb_bt_cg_d.sh"
  fi
done

if [ "${found_binary}" -eq 0 ]; then
  echo
  echo "Environment is correct. Build the NPB binaries next:"
  echo "  ./build_npb_bt_cg_d.sh"
else
  echo
  echo "Environment and available NPB binaries are ready."
fi
