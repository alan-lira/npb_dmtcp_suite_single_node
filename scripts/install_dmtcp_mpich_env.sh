#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# ============================================================
# Reproducible DMTCP + MPICH single-node environment
#
# Builds:
#   - local Autoconf 2.72
#   - the exact DMTCP commit preserved by the working package
#   - MPICH 5.0.0 with Hydra and ch3:nemesis
#   - embedded hwloc with libudev disabled at build time
#
# The preserved checkout reports DMTCP 4.1.0, but it is seven commits after the
# 4.1.0 tag. Pinning the full commit avoids silently installing the wrong code.
#
# Override examples:
#   ROOT_PREFIX=/custom/opt bash install_dmtcp_mpich_env.sh
#   BUILD_ROOT=/custom/build bash install_dmtcp_mpich_env.sh
#
# DMTCP_REF remains overrideable for controlled comparisons, but the experiment
# suite rejects alternatives while REQUIRE_WORKING_STACK=true. MPICH 5.0.0 is
# enforced because the archived source checksum is part of the profile.
# ============================================================

# ---------- Versions / prefixes ----------
AUTOCONF_VER="${AUTOCONF_VER:-2.72}"
MPICH_VER="${MPICH_VER:-5.0.0}"
DMTCP_REF="${DMTCP_REF:-6896e12276a9fe449edb0cf206203ce01b19efe6}"

WORKING_DMTCP_COMMIT="6896e12276a9fe449edb0cf206203ce01b19efe6"
WORKING_DMTCP_RESTORE_LISTEN_BACKLOG="1024"
WORKING_DMTCP_BACKLOG_PATCH_SHA256="72bc6bc3d338a78c9e1ebe89692f12c544e92ad2862be58b8aca942702a981a1"
WORKING_DMTCP_DUPLEX_PATCH_SHA256="f2c7baf517f7f7076a12e5703e36ab089b918b6aff72b544ddf1a59c46db897d"
WORKING_DMTCP_KERNELBUFFERDRAINER_ORIGINAL_SHA256="1913813176868a6226245963b90b5976c802bc70dc3a924d2405c2375b5bf94d"
WORKING_DMTCP_KERNELBUFFERDRAINER_PATCHED_SHA256="c5d7b960220762b6a291f5a1aef5989786ed47c00318dcc78a8fb2b6db9cf04c"
WORKING_MPICH_VER="5.0.0"
WORKING_MPICH_SHA256="e9350e32224283e95311f22134f36c98e3cd1c665d17fae20a6cc92ed3cffe11"

ROOT_PREFIX="${ROOT_PREFIX:-${HOME}/opt}"
BUILD_ROOT="${BUILD_ROOT:-${HOME}/build_dmtcp_mpich}"
BUILD_JOBS="${BUILD_JOBS:-8}"

AUTOCONF_PREFIX="${ROOT_PREFIX}/autoconf-${AUTOCONF_VER}"
MPICH_PREFIX_VERSIONED="${ROOT_PREFIX}/mpich-${MPICH_VER}-ch3-nemesis-no-libudev"
MPICH_PREFIX="${ROOT_PREFIX}/mpich-dmtcp"

DMTCP_REPO="${DMTCP_REPO:-https://github.com/dmtcp/dmtcp.git}"
DMTCP_PATCH_DIR="${REPO_ROOT}/patches/dmtcp-${WORKING_DMTCP_COMMIT}"
DMTCP_BACKLOG_PATCH_FILE="${DMTCP_PATCH_DIR}/connectionrewirer-backlog-1024.exact.patch"
DMTCP_DUPLEX_REFILL_PATCH_FILE="${DMTCP_PATCH_DIR}/kernelbufferdrainer-duplex-refill.patch"
AUTOCONF_URL="https://ftp.gnu.org/gnu/autoconf/autoconf-${AUTOCONF_VER}.tar.xz"
MPICH_URL="https://www.mpich.org/static/downloads/${MPICH_VER}/mpich-${MPICH_VER}.tar.gz"

mkdir -p "${ROOT_PREFIX}" "${BUILD_ROOT}"

preserve_existing_path() {
  local path="$1"
  local backup
  local index=1

  if [ ! -e "${path}" ] && [ ! -L "${path}" ]; then
    return
  fi

  backup="${path}.previous.$(date +%Y%m%d_%H%M%S)"
  while [ -e "${backup}" ] || [ -L "${backup}" ]; do
    backup="${path}.previous.$(date +%Y%m%d_%H%M%S).${index}"
    index=$((index + 1))
  done

  echo "Preserving existing installation:"
  echo "  ${path}"
  echo "as:"
  echo "  ${backup}"
  mv -- "${path}" "${backup}"
}

echo "============================================================"
echo "Installing DMTCP + MPICH environment"
echo "============================================================"
echo "ROOT_PREFIX=${ROOT_PREFIX}"
echo "BUILD_ROOT=${BUILD_ROOT}"
echo "AUTOCONF_VER=${AUTOCONF_VER}"
echo "MPICH_VER=${MPICH_VER}"
echo "DMTCP_REF=${DMTCP_REF}"
echo "DMTCP_REPO=${DMTCP_REPO}"
echo "DMTCP_RESTORE_LISTEN_BACKLOG=${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}"
echo "DMTCP_PATCH_DIR=${DMTCP_PATCH_DIR}"
echo "DMTCP_BACKLOG_PATCH_FILE=${DMTCP_BACKLOG_PATCH_FILE}"
echo "DMTCP_DUPLEX_REFILL_PATCH_FILE=${DMTCP_DUPLEX_REFILL_PATCH_FILE}"
echo "============================================================"

# ---------- Ubuntu build dependencies ----------
echo "[1/9] Installing Ubuntu build dependencies..."
sudo apt update
sudo apt install -y \
  build-essential \
  gfortran \
  git \
  m4 \
  perl \
  patch \
  python3 \
  python3-venv \
  texinfo \
  help2man \
  flex \
  bison \
  wget \
  curl \
  ca-certificates \
  xz-utils \
  tar \
  automake \
  libtool \
  pkg-config \
  libc6-dev \
  libncurses-dev \
  zlib1g-dev \
  libibverbs-dev

cd "${BUILD_ROOT}"

# ---------- Autoconf 2.72 ----------
echo "[2/9] Installing local Autoconf ${AUTOCONF_VER}..."
if [ ! -x "${AUTOCONF_PREFIX}/bin/autoconf" ]; then
  rm -rf "autoconf-${AUTOCONF_VER}" "autoconf-${AUTOCONF_VER}.tar.xz"

  wget -O "autoconf-${AUTOCONF_VER}.tar.xz" "${AUTOCONF_URL}"
  tar -xf "autoconf-${AUTOCONF_VER}.tar.xz"

  cd "autoconf-${AUTOCONF_VER}"
  ./configure --prefix="${AUTOCONF_PREFIX}"
  make -j"${BUILD_JOBS}"
  make install

  cd "${BUILD_ROOT}"
else
  echo "Autoconf ${AUTOCONF_VER} already installed at ${AUTOCONF_PREFIX}"
fi

export PATH="${AUTOCONF_PREFIX}/bin:${PATH}"
hash -r

echo "Using autoconf:"
autoconf --version | head -n 1

# ---------- Resolve DMTCP ref ----------
echo "[3/9] Selecting pinned DMTCP ref..."

DMTCP_REF_SAFE="$(printf "%s" "${DMTCP_REF}" | tr '/:@ ' '____')"
DMTCP_PREFIX_VERSIONED="${ROOT_PREFIX}/dmtcp-${DMTCP_REF_SAFE}"
DMTCP_PREFIX="${ROOT_PREFIX}/dmtcp"

echo "DMTCP_REF=${DMTCP_REF}"
echo "DMTCP_PREFIX_VERSIONED=${DMTCP_PREFIX_VERSIONED}"
echo "DMTCP_PREFIX symlink=${DMTCP_PREFIX}"

# ---------- DMTCP ----------
echo "[4/9] Cloning/updating DMTCP..."

if [ ! -d dmtcp/.git ]; then
  rm -rf dmtcp
  git clone "${DMTCP_REPO}" dmtcp
fi

cd dmtcp

echo "[5/9] Cleaning and checking out DMTCP ref: ${DMTCP_REF}"

# Important:
# Previous autoreconf/configure runs modify generated files such as ./configure.
# These commands force the source tree back to a clean Git state before checkout.
git reset --hard
git clean -fdx
git fetch --all --tags --prune
git checkout --force "${DMTCP_REF}"
git reset --hard "${DMTCP_REF}"
git clean -fdx

DMTCP_COMMIT="$(git rev-parse --short HEAD)"
DMTCP_FULL_COMMIT="$(git rev-parse HEAD)"

echo "DMTCP commit: ${DMTCP_COMMIT}"

if [ "${DMTCP_REF}" = "${WORKING_DMTCP_COMMIT}" ] && \
   [ "${DMTCP_FULL_COMMIT}" != "${WORKING_DMTCP_COMMIT}" ]; then
  echo "ERROR: The checked-out DMTCP commit does not match the working commit." >&2
  echo "  Expected: ${WORKING_DMTCP_COMMIT}" >&2
  echo "  Actual:   ${DMTCP_FULL_COMMIT}" >&2
  exit 1
fi

DMTCP_CONNECTION_REWIRER_SOURCE="${PWD}/src/plugin/ipc/socket/connectionrewirer.cpp"
DMTCP_KERNELBUFFERDRAINER_SOURCE="${PWD}/src/plugin/ipc/socket/kernelbufferdrainer.cpp"

if [ ! -f "${DMTCP_CONNECTION_REWIRER_SOURCE}" ]; then
  echo "ERROR: DMTCP connection rewirer source was not found:" >&2
  echo "  ${DMTCP_CONNECTION_REWIRER_SOURCE}" >&2
  exit 1
fi

if [ ! -f "${DMTCP_KERNELBUFFERDRAINER_SOURCE}" ]; then
  echo "ERROR: DMTCP kernel buffer drainer source was not found:" >&2
  echo "  ${DMTCP_KERNELBUFFERDRAINER_SOURCE}" >&2
  exit 1
fi

DMTCP_RESTORE_BACKLOG_PATCH=0
DMTCP_DUPLEX_REFILL_PATCH=0
DMTCP_BACKLOG_PATCH_FILE_SHA256="not-applied"
DMTCP_DUPLEX_REFILL_PATCH_FILE_SHA256="not-applied"
DMTCP_CONNECTION_REWIRER_SHA256="$(
  sha256sum "${DMTCP_CONNECTION_REWIRER_SOURCE}" | awk '{print $1}'
)"
DMTCP_KERNELBUFFERDRAINER_SHA256="$(
  sha256sum "${DMTCP_KERNELBUFFERDRAINER_SOURCE}" | awk '{print $1}'
)"

if [ "${DMTCP_FULL_COMMIT}" = "${WORKING_DMTCP_COMMIT}" ]; then
  echo "Applying the version-specific DMTCP patch bundle..."

  for required_patch in \
    "${DMTCP_BACKLOG_PATCH_FILE}" \
    "${DMTCP_DUPLEX_REFILL_PATCH_FILE}"
  do
    if [ ! -f "${required_patch}" ]; then
      echo "ERROR: Required DMTCP patch asset was not found:" >&2
      echo "  ${required_patch}" >&2
      exit 1
    fi
  done

  DMTCP_BACKLOG_PATCH_FILE_SHA256="$(
    sha256sum "${DMTCP_BACKLOG_PATCH_FILE}" | awk '{print $1}'
  )"
  if [ "${DMTCP_BACKLOG_PATCH_FILE_SHA256}" != \
       "${WORKING_DMTCP_BACKLOG_PATCH_SHA256}" ]; then
    echo "ERROR: DMTCP backlog patch checksum mismatch." >&2
    echo "  Expected: ${WORKING_DMTCP_BACKLOG_PATCH_SHA256}" >&2
    echo "  Actual:   ${DMTCP_BACKLOG_PATCH_FILE_SHA256}" >&2
    exit 1
  fi

  DMTCP_DUPLEX_REFILL_PATCH_FILE_SHA256="$(
    sha256sum "${DMTCP_DUPLEX_REFILL_PATCH_FILE}" | awk '{print $1}'
  )"
  if [ "${DMTCP_DUPLEX_REFILL_PATCH_FILE_SHA256}" != \
       "${WORKING_DMTCP_DUPLEX_PATCH_SHA256}" ]; then
    echo "ERROR: DMTCP duplex-refill patch checksum mismatch." >&2
    echo "  Expected: ${WORKING_DMTCP_DUPLEX_PATCH_SHA256}" >&2
    echo "  Actual:   ${DMTCP_DUPLEX_REFILL_PATCH_FILE_SHA256}" >&2
    exit 1
  fi

  echo "Applying restore-listener backlog patch asset:"
  echo "  ${DMTCP_BACKLOG_PATCH_FILE}"
  python3 - \
    "${DMTCP_CONNECTION_REWIRER_SOURCE}" \
    "${DMTCP_BACKLOG_PATCH_FILE}" <<'PY'
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
patch_path = Path(sys.argv[2])

entries = []
for line_number, raw_line in enumerate(patch_path.read_text().splitlines(), 1):
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        raise SystemExit(
            f"ERROR: malformed exact patch line {line_number}: {raw_line!r}"
        )
    kind, value = line.split("=", 1)
    if kind not in {"FROM", "TO"}:
        raise SystemExit(
            f"ERROR: unsupported exact patch directive {kind!r} "
            f"on line {line_number}."
        )
    entries.append((kind, value))

if len(entries) != 8:
    raise SystemExit(
        f"ERROR: expected four FROM/TO pairs; found {len(entries)} directives."
    )

pairs = []
for index in range(0, len(entries), 2):
    from_kind, old = entries[index]
    to_kind, new = entries[index + 1]
    if from_kind != "FROM" or to_kind != "TO":
        raise SystemExit(
            "ERROR: exact patch directives must alternate FROM then TO."
        )
    if not old or not new or old == new:
        raise SystemExit("ERROR: invalid empty or identical FROM/TO pair.")
    pairs.append((old, new))

text = source_path.read_text()
for old, new in pairs:
    old_count = text.count(old)
    new_count = text.count(new)
    if old_count != 1:
        raise SystemExit(
            f"ERROR: expected exactly one occurrence of {old!r}; "
            f"found {old_count}."
        )
    if new_count != 0:
        raise SystemExit(
            f"ERROR: replacement {new!r} already occurs {new_count} time(s)."
        )
    text = text.replace(old, new, 1)

for old, new in pairs:
    if old in text or text.count(new) != 1:
        raise SystemExit(
            f"ERROR: post-application verification failed for {old!r}."
        )

source_path.write_text(text)
PY

  RESTORE_LISTEN_CALL_COUNT="$(
    grep -Ec "_real_listen\((ip6fd|udsfd|udsseqfd), ${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}\)" \
      "${DMTCP_CONNECTION_REWIRER_SOURCE}"
  )"
  RESTORE_IPV4_LISTENER_COUNT="$(
    grep -Fc "jalib::JServerSocket restoreSocket(sockAddr, 0, ${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG});" \
      "${DMTCP_CONNECTION_REWIRER_SOURCE}"
  )"
  if [ "${RESTORE_LISTEN_CALL_COUNT}" -ne 3 ] || \
     [ "${RESTORE_IPV4_LISTENER_COUNT}" -ne 1 ]; then
    echo "ERROR: DMTCP restore-listener backlog patch verification failed." >&2
    grep -nE 'JServerSocket restoreSocket|_real_listen\((ip6fd|udsfd|udsseqfd),' \
      "${DMTCP_CONNECTION_REWIRER_SOURCE}" >&2 || true
    exit 1
  fi
  if grep -Fq 'jalib::JServerSocket restoreSocket(sockAddr, 0);' \
      "${DMTCP_CONNECTION_REWIRER_SOURCE}" || \
     grep -Eq '_real_listen\((ip6fd|udsfd|udsseqfd), 32\)' \
      "${DMTCP_CONNECTION_REWIRER_SOURCE}"; then
    echo "ERROR: At least one DMTCP restore listener still uses backlog 32." >&2
    exit 1
  fi
  DMTCP_RESTORE_BACKLOG_PATCH=1
  DMTCP_CONNECTION_REWIRER_SHA256="$(
    sha256sum "${DMTCP_CONNECTION_REWIRER_SOURCE}" | awk '{print $1}'
  )"
  grep -nE 'JServerSocket restoreSocket|_real_listen\((ip6fd|udsfd|udsseqfd),' \
    "${DMTCP_CONNECTION_REWIRER_SOURCE}"

  echo "Applying nonblocking duplex stream-refill patch asset:"
  echo "  ${DMTCP_DUPLEX_REFILL_PATCH_FILE}"
  if [ "${DMTCP_KERNELBUFFERDRAINER_SHA256}" != \
       "${WORKING_DMTCP_KERNELBUFFERDRAINER_ORIGINAL_SHA256}" ]; then
    echo "ERROR: The checked-out kernelbufferdrainer.cpp does not match" >&2
    echo "the validated source for the pinned DMTCP commit." >&2
    echo "  Expected: ${WORKING_DMTCP_KERNELBUFFERDRAINER_ORIGINAL_SHA256}" >&2
    echo "  Actual:   ${DMTCP_KERNELBUFFERDRAINER_SHA256}" >&2
    exit 1
  fi

  patch --batch --forward --fuzz=0 -p1 \
    < "${DMTCP_DUPLEX_REFILL_PATCH_FILE}"

  DMTCP_KERNELBUFFERDRAINER_SHA256="$(
    sha256sum "${DMTCP_KERNELBUFFERDRAINER_SOURCE}" | awk '{print $1}'
  )"
  if [ "${DMTCP_KERNELBUFFERDRAINER_SHA256}" != \
       "${WORKING_DMTCP_KERNELBUFFERDRAINER_PATCHED_SHA256}" ]; then
    echo "ERROR: DMTCP duplex stream-refill patch verification failed." >&2
    echo "  Expected: ${WORKING_DMTCP_KERNELBUFFERDRAINER_PATCHED_SHA256}" >&2
    echo "  Actual:   ${DMTCP_KERNELBUFFERDRAINER_SHA256}" >&2
    exit 1
  fi
  if ! grep -Fq '#include <poll.h>' "${DMTCP_KERNELBUFFERDRAINER_SOURCE}"; then
    echo "ERROR: poll support is missing from the patched source." >&2
    exit 1
  fi
  if ! grep -Fq 'stream-refill payload send failed' \
      "${DMTCP_KERNELBUFFERDRAINER_SOURCE}"; then
    echo "ERROR: duplex-refill state machine marker is missing." >&2
    exit 1
  fi
  DMTCP_DUPLEX_REFILL_PATCH=1
else
  echo "WARNING: Skipping the version-specific DMTCP patch bundle" >&2
  echo "because DMTCP_REF does not resolve to the validated working commit." >&2
fi

echo "DMTCP restore-backlog patch:      ${DMTCP_RESTORE_BACKLOG_PATCH}"
echo "DMTCP duplex stream-refill patch: ${DMTCP_DUPLEX_REFILL_PATCH}"
echo "connectionrewirer.cpp SHA256:      ${DMTCP_CONNECTION_REWIRER_SHA256}"
echo "kernelbufferdrainer.cpp SHA256:    ${DMTCP_KERNELBUFFERDRAINER_SHA256}"

KERNEL_SOMAXCONN="$(cat /proc/sys/net/core/somaxconn)"
if ! [[ "${KERNEL_SOMAXCONN}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Could not read a numeric net.core.somaxconn value." >&2
  exit 1
fi

if [ "${KERNEL_SOMAXCONN}" -lt "${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}" ]; then
  echo "Increasing net.core.somaxconn from ${KERNEL_SOMAXCONN} to ${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}..."
  sudo sysctl -w "net.core.somaxconn=${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}"
  KERNEL_SOMAXCONN="$(cat /proc/sys/net/core/somaxconn)"
fi

if [ "${KERNEL_SOMAXCONN}" -lt "${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}" ]; then
  echo "ERROR: net.core.somaxconn is smaller than the patched DMTCP restore backlog." >&2
  echo "  Required minimum: ${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}" >&2
  echo "  Active value:     ${KERNEL_SOMAXCONN}" >&2
  exit 1
fi

echo "DMTCP restore-listener backlog: ${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}"
echo "Kernel net.core.somaxconn:      ${KERNEL_SOMAXCONN}"

echo "[6/9] Generating build system and building DMTCP..."

# Some branches/tags include generated files, but using autoreconf keeps the
# procedure consistent for Git checkouts.
autoreconf -fi

preserve_existing_path "${DMTCP_PREFIX_VERSIONED}"

./configure --prefix="${DMTCP_PREFIX_VERSIONED}"

make -j"${BUILD_JOBS}"
make install

DMTCP_IPC_PLUGIN="${DMTCP_PREFIX_VERSIONED}/lib/dmtcp/libdmtcp_ipc.so"
if [ ! -f "${DMTCP_IPC_PLUGIN}" ]; then
  echo "ERROR: Installed DMTCP IPC plugin was not found:" >&2
  echo "  ${DMTCP_IPC_PLUGIN}" >&2
  exit 1
fi

if [ "${DMTCP_DUPLEX_REFILL_PATCH}" = "1" ]; then
  if ! grep -aFq 'stream-refill header receive failed' "${DMTCP_IPC_PLUGIN}"; then
    echo "ERROR: Installed IPC plugin lacks the duplex-refill header marker." >&2
    exit 1
  fi
  if ! grep -aFq 'stream-refill payload send failed' "${DMTCP_IPC_PLUGIN}"; then
    echo "ERROR: Installed IPC plugin lacks the duplex-refill payload marker." >&2
    exit 1
  fi
fi
DMTCP_IPC_PLUGIN_SHA256="$(sha256sum "${DMTCP_IPC_PLUGIN}" | awk '{print $1}')"

cd "${BUILD_ROOT}"

if [ -e "${DMTCP_PREFIX}" ] && [ ! -L "${DMTCP_PREFIX}" ]; then
  preserve_existing_path "${DMTCP_PREFIX}"
fi
ln -sfn "${DMTCP_PREFIX_VERSIONED}" "${DMTCP_PREFIX}"

if [ ! -L "${DMTCP_PREFIX}" ]; then
  echo "ERROR: Failed to create DMTCP symlink: ${DMTCP_PREFIX}" >&2
  exit 1
fi

ACTIVE_DMTCP_PREFIX="$(readlink -f "${DMTCP_PREFIX}")"
EXPECTED_DMTCP_PREFIX="$(readlink -f "${DMTCP_PREFIX_VERSIONED}")"

if [ "${ACTIVE_DMTCP_PREFIX}" != "${EXPECTED_DMTCP_PREFIX}" ]; then
  echo "ERROR: DMTCP symlink points to an unexpected location." >&2
  echo "  Expected: ${EXPECTED_DMTCP_PREFIX}" >&2
  echo "  Actual:   ${ACTIVE_DMTCP_PREFIX}" >&2
  exit 1
fi

echo "Active DMTCP symlink:"
echo "  ${DMTCP_PREFIX} -> ${DMTCP_PREFIX_VERSIONED}"

# ---------- MPICH ----------
echo "[7/9] Downloading/building MPICH ${MPICH_VER}..."

if [ "${MPICH_VER}" != "${WORKING_MPICH_VER}" ]; then
  echo "ERROR: This reproducibility installer requires MPICH ${WORKING_MPICH_VER}." >&2
  echo "Requested MPICH_VER=${MPICH_VER}" >&2
  exit 1
fi

if [ ! -f "mpich-${MPICH_VER}.tar.gz" ]; then
  wget -O "mpich-${MPICH_VER}.tar.gz" "${MPICH_URL}"
fi

ACTUAL_MPICH_SHA256="$(sha256sum "mpich-${MPICH_VER}.tar.gz" | awk '{print $1}')"
if [ "${ACTUAL_MPICH_SHA256}" != "${WORKING_MPICH_SHA256}" ]; then
  echo "ERROR: MPICH source archive checksum mismatch." >&2
  echo "  Expected: ${WORKING_MPICH_SHA256}" >&2
  echo "  Actual:   ${ACTUAL_MPICH_SHA256}" >&2
  echo "Remove ${BUILD_ROOT}/mpich-${MPICH_VER}.tar.gz and rerun the installer." >&2
  exit 1
fi

rm -rf "mpich-${MPICH_VER}"
tar -xf "mpich-${MPICH_VER}.tar.gz"

cd "mpich-${MPICH_VER}"

preserve_existing_path "${MPICH_PREFIX_VERSIONED}"

# MPICH 5.0.0's bundled hwloc understands --disable-libudev, but the MPICH
# top-level configure.ac does not register that forwarded option. Register it
# before regenerating configure so the option is accepted without an
# "unrecognized options" warning and remains available to embedded hwloc.
echo "Registering --disable-libudev in MPICH's top-level configure..."
python3 - <<'PY_MPICH_CONFIGURE'
from pathlib import Path

path = Path("configure.ac")
text = path.read_text()

if "AC_ARG_ENABLE([libudev]" not in text:
    marker = "# options passed to hwloc configure\n"
    insertion = """# options passed to hwloc configure
AC_ARG_ENABLE([libudev],
    [AS_HELP_STRING([--disable-libudev],
        [disable libudev support in embedded hwloc])])
"""

    if marker not in text:
        raise SystemExit(
            "ERROR: Could not locate the MPICH hwloc configure-option section."
        )

    text = text.replace(marker, insertion, 1)
    path.write_text(text)
PY_MPICH_CONFIGURE

autoconf -f

if ! ./configure --help | grep -Fq -- '--disable-libudev'; then
  echo "ERROR: Regenerated MPICH configure does not expose --disable-libudev." >&2
  exit 1
fi

if ! ./configure --help | grep -Fq -- '--with-hwloc'; then
  echo "ERROR: MPICH configure does not expose --with-hwloc." >&2
  exit 1
fi

MPICH_CONFIGURE_OUTPUT="${BUILD_ROOT}/mpich-${MPICH_VER}-configure-output.log"
rm -f "${MPICH_CONFIGURE_OUTPUT}"

# Force the bundled hwloc implementation. The cache values provide an
# additional guard against accidental libudev detection if the embedded hwloc
# implementation changes its internal probing while retaining these standard
# Autoconf checks.
if ! env \
    ac_cv_header_libudev_h=no \
    ac_cv_lib_udev_udev_new=no \
    ./configure \
      --prefix="${MPICH_PREFIX_VERSIONED}" \
      --with-device=ch3:nemesis \
      --with-hwloc=embedded \
      --disable-libudev \
      2>&1 | tee "${MPICH_CONFIGURE_OUTPUT}"; then
  echo "ERROR: MPICH configure failed." >&2
  exit 1
fi

if grep -Eq 'unrecognized options:.*--disable-libudev' \
    "${MPICH_CONFIGURE_OUTPUT}"; then
  echo "ERROR: MPICH still reports --disable-libudev as unrecognized." >&2
  exit 1
fi

# MPICH may configure the embedded hwloc component lazily during the build.
# Build first, then verify the generated private hwloc configuration header.
# Checking for this header immediately after the top-level ./configure caused
# false failures even though MPICH configuration itself had completed.
make -j"${BUILD_JOBS}"

# Do not assume a single source-layout-dependent location. Detect the private
# hwloc configuration header after the embedded component has been built.
HWLOC_CONFIG_HEADER="$(
  find modules/hwloc \
    -type f \
    -path '*/include/private/autogen/config.h' \
    -print \
    -quit
)"

if [ -z "${HWLOC_CONFIG_HEADER}" ]; then
  echo "ERROR: Embedded hwloc configuration header was not generated after the MPICH build." >&2
  echo "Searched below: ${PWD}/modules/hwloc" >&2
  exit 1
fi

HWLOC_CONFIG_HEADER_ABS="$(readlink -f "${HWLOC_CONFIG_HEADER}")"
echo "Embedded hwloc configuration header:"
echo "  ${HWLOC_CONFIG_HEADER_ABS}"

if grep -Eq '^[[:space:]]*#define[[:space:]]+(HAVE_LIBUDEV_H|HWLOC_HAVE_LIBUDEV)[[:space:]]+1' \
    "${HWLOC_CONFIG_HEADER_ABS}"; then
  echo "ERROR: Embedded hwloc unexpectedly enabled libudev." >&2
  exit 1
fi

echo "Embedded hwloc libudev support: disabled"

make install

cd "${BUILD_ROOT}"

if [ -e "${MPICH_PREFIX}" ] && [ ! -L "${MPICH_PREFIX}" ]; then
  preserve_existing_path "${MPICH_PREFIX}"
fi
ln -sfn "${MPICH_PREFIX_VERSIONED}" "${MPICH_PREFIX}"

if [ "$(readlink -f "${MPICH_PREFIX}")" != "$(readlink -f "${MPICH_PREFIX_VERSIONED}")" ]; then
  echo "ERROR: MPICH active symlink points to an unexpected location." >&2
  exit 1
fi

# ---------- Reproducibility manifest ----------
echo "[8/9] Writing and validating the build manifest..."

DMTCP_MPICH_MANIFEST="${ROOT_PREFIX}/dmtcp_mpich_single_node_manifest.txt"

{
  echo "profile=DMTCP_MPICH_SINGLE_NODE"
  echo "profile_version=6"
  echo "build_timestamp=$(date -Is)"
  echo "kernel=$(uname -srvo)"
  echo "gcc=$(gcc --version | head -n 1)"
  echo "gfortran=$(gfortran --version | head -n 1)"
  echo "autoconf_version=${AUTOCONF_VER}"
  echo "autoconf_home=${AUTOCONF_PREFIX}"
  echo "dmtcp_ref=${DMTCP_REF}"
  echo "dmtcp_commit=${DMTCP_FULL_COMMIT}"
  echo "dmtcp_home=${DMTCP_PREFIX}"
  echo "dmtcp_versioned_home=${DMTCP_PREFIX_VERSIONED}"
  echo "dmtcp_restore_listen_backlog=${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}"
  echo "dmtcp_restore_listener_paths=4"
  echo "dmtcp_restore_backlog_patch=${DMTCP_RESTORE_BACKLOG_PATCH}"
  echo "dmtcp_backlog_patch_file_sha256=${DMTCP_BACKLOG_PATCH_FILE_SHA256}"
  echo "dmtcp_connectionrewirer_sha256=${DMTCP_CONNECTION_REWIRER_SHA256}"
  echo "dmtcp_duplex_refill_patch=${DMTCP_DUPLEX_REFILL_PATCH}"
  echo "dmtcp_duplex_patch_file_sha256=${DMTCP_DUPLEX_REFILL_PATCH_FILE_SHA256}"
  echo "dmtcp_kernelbufferdrainer_sha256=${DMTCP_KERNELBUFFERDRAINER_SHA256}"
  echo "dmtcp_ipc_plugin_sha256=${DMTCP_IPC_PLUGIN_SHA256}"
  echo "kernel_net_core_somaxconn=${KERNEL_SOMAXCONN}"
  echo "dmtcp_launch_sha256=$(sha256sum "${DMTCP_PREFIX_VERSIONED}/bin/dmtcp_launch" | awk '{print $1}')"
  echo "mpich_version=${MPICH_VER}"
  echo "mpich_source_sha256=${ACTUAL_MPICH_SHA256}"
  echo "mpich_device=ch3:nemesis"
  echo "mpich_hwloc=embedded"
  echo "mpich_hwloc_libudev=disabled"
  echo "mpich_hwloc_config_header=${HWLOC_CONFIG_HEADER_ABS}"
  echo "mpich_configure=--with-device=ch3:nemesis --with-hwloc=embedded --disable-libudev"
  echo "mpich_home=${MPICH_PREFIX}"
  echo "mpich_versioned_home=${MPICH_PREFIX_VERSIONED}"
  echo "mpiexec_hydra_sha256=$(sha256sum "${MPICH_PREFIX_VERSIONED}/bin/mpiexec.hydra" | awk '{print $1}')"
  echo "hydra_pmi_proxy_sha256=$(sha256sum "${MPICH_PREFIX_VERSIONED}/bin/hydra_pmi_proxy" | awk '{print $1}')"
} > "${DMTCP_MPICH_MANIFEST}"

# ---------- Environment helper ----------
echo "[9/9] Writing environment helper..."

if [ "${DMTCP_FULL_COMMIT}" = "${WORKING_DMTCP_COMMIT}" ] && \
   [ "${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}" = "1024" ] && \
   [ "${DMTCP_RESTORE_BACKLOG_PATCH}" = "1" ] && \
   [ "${DMTCP_DUPLEX_REFILL_PATCH}" = "1" ] && \
   [ "${DMTCP_KERNELBUFFERDRAINER_SHA256}" = \
     "${WORKING_DMTCP_KERNELBUFFERDRAINER_PATCHED_SHA256}" ]; then
  DMTCP_SINGLE_NODE_PROFILE=1
else
  DMTCP_SINGLE_NODE_PROFILE=0
fi

cat > "${ROOT_PREFIX}/enable_dmtcp_mpich_env.sh" <<EOF
#!/usr/bin/env bash

# DMTCP + MPICH environment generated by install_dmtcp_mpich_env.sh

export DMTCP_HOME="${DMTCP_PREFIX}"
export DMTCP_VERSIONED_HOME="${DMTCP_PREFIX_VERSIONED}"
export DMTCP_REF="${DMTCP_REF}"
export DMTCP_COMMIT="${DMTCP_FULL_COMMIT}"
export DMTCP_SINGLE_NODE_PROFILE="${DMTCP_SINGLE_NODE_PROFILE}"
export DMTCP_RESTORE_LISTEN_BACKLOG="${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG}"
export DMTCP_RESTORE_LISTENER_PATHS="4"
export DMTCP_RESTORE_BACKLOG_PATCH="${DMTCP_RESTORE_BACKLOG_PATCH}"
export DMTCP_DUPLEX_REFILL_PATCH="${DMTCP_DUPLEX_REFILL_PATCH}"
export DMTCP_KERNELBUFFERDRAINER_SHA256="${DMTCP_KERNELBUFFERDRAINER_SHA256}"
export DMTCP_IPC_PLUGIN_SHA256="${DMTCP_IPC_PLUGIN_SHA256}"
export DMTCP_MPICH_MANIFEST="${DMTCP_MPICH_MANIFEST}"

export MPICH_HOME="${MPICH_PREFIX}"
export MPICH_VERSIONED_HOME="${MPICH_PREFIX_VERSIONED}"
export MPICH_VERSION="${MPICH_VER}"
export MPICH_DEVICE="ch3:nemesis"
export MPICH_HWLOC="embedded"
export MPICH_HWLOC_LIBUDEV="disabled"
export AUTOCONF_HOME="${AUTOCONF_PREFIX}"

export PATH="\${DMTCP_HOME}/bin:\${MPICH_HOME}/bin:\${AUTOCONF_HOME}/bin:\$PATH"
# Do not carry libraries from previously sourced DMTCP/MPICH installations into
# the experiment. System libraries remain available through the normal loader
# search path.
export DMTCP_PREVIOUS_LD_LIBRARY_PATH="\${LD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="\${MPICH_HOME}/lib"

# Runtime settings from the preserved successful single-node profile.
export MPICH_NO_LOCAL=1
export DMTCP_SIGCKPT="\${DMTCP_SIGCKPT:-30}"

# The working MPICH embedded hwloc was compiled without libudev and did not use
# a HWLOC_COMPONENTS override. Clear values inherited from the previously
# tested runtime workaround so this shell reproduces that behavior.
unset HWLOC_COMPONENTS
unset MPIR_CVAR_ENABLE_GPU

# Optional debugging:
# export DMTCP_VERBOSE=1
EOF

chmod +x "${ROOT_PREFIX}/enable_dmtcp_mpich_env.sh"

# ---------- Optional bashrc hook ----------
echo "Adding optional shell alias to ~/.bashrc..."

if ! grep -Fq 'enable_dmtcp_mpich_env.sh' "${HOME}/.bashrc"; then
  {
    echo ""
    echo "# DMTCP + MPICH working environment"
    echo "alias enable_dmtcp_mpich_env='source ${ROOT_PREFIX}/enable_dmtcp_mpich_env.sh'"
  } >> "${HOME}/.bashrc"
fi

# ---------- Verify ----------
source "${ROOT_PREFIX}/enable_dmtcp_mpich_env.sh"

echo "------------------------------------------------------------"
echo "Verification"
echo "------------------------------------------------------------"
echo "DMTCP_REF:          ${DMTCP_REF}"
echo "DMTCP_COMMIT:       ${DMTCP_FULL_COMMIT}"
echo "DMTCP_HOME:         ${DMTCP_HOME}"
echo "DMTCP_VERSIONED:    ${DMTCP_VERSIONED_HOME}"
echo "MPICH_HOME:         ${MPICH_HOME}"
echo "MPICH_VERSIONED:    ${MPICH_VERSIONED_HOME}"
echo "AUTOCONF_HOME:      ${AUTOCONF_HOME}"
echo "PROFILE:            ${DMTCP_SINGLE_NODE_PROFILE}"
echo "RESTORE_BACKLOG:    ${DMTCP_RESTORE_LISTEN_BACKLOG}"
echo "DUPLEX_REFILL:      ${DMTCP_DUPLEX_REFILL_PATCH}"
echo "KBD_SHA256:         ${DMTCP_KERNELBUFFERDRAINER_SHA256}"
echo "IPC_PLUGIN_SHA256:  ${DMTCP_IPC_PLUGIN_SHA256}"
echo "KERNEL_SOMAXCONN:   $(cat /proc/sys/net/core/somaxconn)"
echo "MANIFEST:           ${DMTCP_MPICH_MANIFEST}"
echo "MPICH_DEVICE:       ${MPICH_DEVICE}"
echo "MPICH_HWLOC:        ${MPICH_HWLOC}"
echo "MPICH_LIBUDEV:      ${MPICH_HWLOC_LIBUDEV}"
echo "HWLOC_COMPONENTS:   ${HWLOC_COMPONENTS:-unset}"
echo "MPICH_NO_LOCAL:     ${MPICH_NO_LOCAL}"
echo "DMTCP_SIGCKPT:      ${DMTCP_SIGCKPT}"
echo
echo "dmtcp_launch:       $(command -v dmtcp_launch || true)"
echo "dmtcp_command:      $(command -v dmtcp_command || true)"
echo "dmtcp_coordinator:  $(command -v dmtcp_coordinator || true)"
echo "mpicc:              $(command -v mpicc || true)"
echo "mpirun:             $(command -v mpirun || true)"
echo
echo "DMTCP version:"
dmtcp_launch --version || true
echo
echo "MPICH version:"
mpirun -version || true
echo
echo "Checking dmtcp_command help for --list:"
dmtcp_command --help 2>&1 | grep -E -- '--list|list' || true

echo
echo "Checking dmtcp_command help for --checkpoint and --kill:"
dmtcp_command --help 2>&1 | grep -E -- '--checkpoint|--kill|checkpoint|kill' || true

echo
echo "Checking embedded hwloc build setting:"
echo "  Configuration header: ${HWLOC_CONFIG_HEADER_ABS}"
if grep -Eq '^[[:space:]]*#define[[:space:]]+(HAVE_LIBUDEV_H|HWLOC_HAVE_LIBUDEV)[[:space:]]+1' \
    "${HWLOC_CONFIG_HEADER_ABS}"; then
  echo "ERROR: libudev is enabled in embedded hwloc." >&2
  exit 1
else
  echo "Embedded hwloc libudev support: disabled"
fi

echo
echo "Build manifest:"
cat "${DMTCP_MPICH_MANIFEST}"

echo "============================================================"
echo "Done."
echo
echo "To enable the runtime environment in a new shell:"
echo "  source ${ROOT_PREFIX}/enable_dmtcp_mpich_env.sh"
echo
echo "or after reopening the shell:"
echo "  enable_dmtcp_mpich_env"
echo
echo "This helper selects the exact preserved single-node stack."
echo "Rebuild the NPB applications with build_npb_bt_cg_d.sh before running."
echo "============================================================"
