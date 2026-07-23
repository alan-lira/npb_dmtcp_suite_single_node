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
echo "Socket cleanup delay:  ${SOCKET_CLEANUP_SLEEP_SECONDS}s"
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
