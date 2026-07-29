#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

NPB_VERSION="${NPB_VERSION:-3.4.4}"
NPB_URL="${NPB_URL:-https://www.nas.nasa.gov/assets/npb/NPB${NPB_VERSION}.tar.gz}"
NPB_TARGET="${NPB_TARGET:-${HOME}/NPB3.4-MPI}"

log() {
    printf '%s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v tar >/dev/null 2>&1 || fail "tar is required."
command -v find >/dev/null 2>&1 || fail "find is required."

if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    fail "Neither curl nor wget is installed. Install one with: sudo apt-get update && sudo apt-get install -y curl"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/npb-install.XXXXXX")"
ARCHIVE="${TMP_DIR}/NPB${NPB_VERSION}.tar.gz"
EXTRACT_DIR="${TMP_DIR}/extract"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${EXTRACT_DIR}"

log "Downloading official NAS Parallel Benchmarks ${NPB_VERSION}..."
log "  Source: ${NPB_URL}"

if [[ "${DOWNLOADER}" == "curl" ]]; then
    curl --fail --location --retry 3 --retry-delay 2 \
        --output "${ARCHIVE}" "${NPB_URL}"
else
    wget --tries=3 --timeout=30 \
        --output-document="${ARCHIVE}" "${NPB_URL}"
fi

[[ -s "${ARCHIVE}" ]] || fail "The downloaded archive is empty."
tar -tzf "${ARCHIVE}" >/dev/null || fail "The downloaded file is not a valid gzip-compressed tar archive."

log "Extracting archive..."
tar -xzf "${ARCHIVE}" -C "${EXTRACT_DIR}"

NPB_MPI_SOURCE="$(
    find "${EXTRACT_DIR}" \
        -type d \
        -name 'NPB3.4-MPI' \
        -print \
        -quit
)"

[[ -n "${NPB_MPI_SOURCE}" ]] || fail "Could not locate the NPB3.4-MPI source directory inside the archive."
[[ -f "${NPB_MPI_SOURCE}/config/make.def.template" ]] || \
    fail "Located NPB3.4-MPI, but config/make.def.template is missing."

if [[ -e "${NPB_TARGET}" || -L "${NPB_TARGET}" ]]; then
    BACKUP="${NPB_TARGET}.previous.$(date +%Y%m%d_%H%M%S)"
    log "Existing target found; preserving it as:"
    log "  ${BACKUP}"
    mv "${NPB_TARGET}" "${BACKUP}"
fi

mkdir -p "$(dirname "${NPB_TARGET}")"
cp -a "${NPB_MPI_SOURCE}" "${NPB_TARGET}"

[[ -f "${NPB_TARGET}/config/make.def.template" ]] || \
    fail "Installation verification failed: make.def.template was not installed."

log ""
log "NPB-MPI installation completed successfully."
log ""
log "Installed source directory:"
log "  ${NPB_TARGET}"
log ""
log "Next commands:"
log "  cd ${SCRIPT_DIR}"
log "  ./build_npb_bt_cg_d.sh"
