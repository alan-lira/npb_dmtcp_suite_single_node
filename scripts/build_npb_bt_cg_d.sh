#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=experiment_config.sh
source "${SCRIPT_DIR}/experiment_config.sh"

if [ ! -f "${ENV_FILE}" ]; then
  echo "ERROR: DMTCP/MPICH environment helper not found:"
  echo "  ${ENV_FILE}"
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

if ! verify_single_node_stack; then
  echo "ERROR: The exact working single-node DMTCP/MPICH stack is not active." >&2
  exit 1
fi

for command_name in mpifort mpicc mpirun dmtcp_launch dmtcp_command; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: Required command is unavailable after sourcing ${ENV_FILE}:"
    echo "  ${command_name}"
    if [ "${command_name}" = "mpifort" ]; then
      echo "Install gfortran before building MPICH, then rebuild MPICH so its"
      echo "Fortran compiler wrappers and bindings are generated."
    fi
    exit 1
  fi
done

if [ ! -d "${NPB_ROOT}" ]; then
  echo "ERROR: NPB source directory not found:"
  echo "  ${NPB_ROOT}"
  exit 1
fi

if [ ! -f "${NPB_ROOT}/config/make.def.template" ]; then
  echo "ERROR: NPB make definition template not found:"
  echo "  ${NPB_ROOT}/config/make.def.template"
  exit 1
fi

for benchmark in "${BENCHMARKS[@]}"; do
  case "${benchmark}" in
    bt|cg)
      ;;
    *)
      echo "ERROR: This experiment suite supports only bt and cg."
      echo "Invalid benchmark: ${benchmark}"
      exit 1
      ;;
  esac
done

mkdir -p "${BINARY_ROOT}"

cd "${NPB_ROOT}"
cp config/make.def.template config/make.def

# NPB 3.4 uses MPIFC and MPICC.
if grep -Eq '^[[:space:]]*MPIFC[[:space:]]*=' config/make.def; then
  sed -i 's|^[[:space:]]*MPIFC[[:space:]]*=.*|MPIFC = mpifort|' config/make.def
fi


if grep -Eq '^[[:space:]]*MPICC[[:space:]]*=' config/make.def; then
  sed -i 's|^[[:space:]]*MPICC[[:space:]]*=.*|MPICC = mpicc|' config/make.def
fi

echo "============================================================"
echo "Building NPB-MPI benchmarks"
echo "NPB root:       ${NPB_ROOT}"
echo "Class:          ${NPB_CLASS}"
echo "Benchmarks:     ${BENCHMARKS[*]}"
echo "Experiment bin: ${BINARY_ROOT}"
echo "mpifort:        $(command -v mpifort)"
echo "mpicc:          $(command -v mpicc)"
echo "============================================================"

make clean || true

for benchmark in "${BENCHMARKS[@]}"; do
  echo
  echo "Building ${benchmark^^}.${NPB_CLASS}..."
  make "${benchmark}" "CLASS=${NPB_CLASS}"

  source_binary="${NPB_ROOT}/bin/${benchmark}.${NPB_CLASS}.x"
  target_binary="${BINARY_ROOT}/${benchmark}.${NPB_CLASS}.x"

  if [ ! -x "${source_binary}" ]; then
    echo "ERROR: Build completed without producing the expected executable:"
    echo "  ${source_binary}"
    exit 1
  fi

  cp -f "${source_binary}" "${target_binary}"
  chmod +x "${target_binary}"

  mpi_linkage="$(ldd "${target_binary}" 2>/dev/null || true)"
  if ! printf "%s\n" "${mpi_linkage}" | grep -F "${MPICH_HOME}/" >/dev/null && \
     ! printf "%s\n" "${mpi_linkage}" | grep -F "$(readlink -f "${MPICH_HOME}")/" >/dev/null; then
    echo "ERROR: ${target_binary} is not linked to the active MPICH installation." >&2
    echo "${mpi_linkage}" >&2
    exit 1
  fi
done

{
  echo "Build timestamp: $(date -Is)"
  echo "NPB root: ${NPB_ROOT}"
  echo "NPB class: ${NPB_CLASS}"
  echo "Benchmarks: ${BENCHMARKS[*]}"
  echo "Requested MPI ranks for experiments: ${MPI_RANKS[*]}"
  echo "DMTCP ref: ${DMTCP_REF:-unknown}"
  echo "DMTCP commit: ${DMTCP_COMMIT:-unknown}"
  echo "DMTCP home: ${DMTCP_HOME:-unknown}"
  echo "MPICH home: ${MPICH_HOME:-unknown}"
  echo "MPICH versioned home: ${MPICH_VERSIONED_HOME:-unknown}"
  echo "MPICH version: ${MPICH_VERSION:-unknown}"
  echo "MPICH device: ${MPICH_DEVICE:-unknown}"
  echo "MPICH embedded hwloc libudev: ${MPICH_HWLOC_LIBUDEV:-unknown}"
  echo "Working-stack manifest: ${DMTCP_MPICH_MANIFEST:-unknown}"
  echo
  echo "mpifort -show:"
  mpifort -show 2>&1 || true
  echo
  echo "mpirun -version:"
  mpirun -version 2>&1 || true
  echo
  echo "Executables:"
  for benchmark in "${BENCHMARKS[@]}"; do
    ls -lh "${BINARY_ROOT}/${benchmark}.${NPB_CLASS}.x"
    sha256sum "${BINARY_ROOT}/${benchmark}.${NPB_CLASS}.x"
    echo
    echo "Dynamic dependencies for ${benchmark}.${NPB_CLASS}.x:"
    ldd "${BINARY_ROOT}/${benchmark}.${NPB_CLASS}.x" || true
    echo
    echo "Dynamic search path for ${benchmark}.${NPB_CLASS}.x:"
    readelf -d "${BINARY_ROOT}/${benchmark}.${NPB_CLASS}.x" \
      | grep -E 'RPATH|RUNPATH|NEEDED' || true
  done
} > "${BINARY_ROOT}/build_metadata.txt"

echo
echo "Built experiment binaries:"
for benchmark in "${BENCHMARKS[@]}"; do
  ls -lh "${BINARY_ROOT}/${benchmark}.${NPB_CLASS}.x"
done

echo
echo "Build metadata:"
echo "  ${BINARY_ROOT}/build_metadata.txt"
