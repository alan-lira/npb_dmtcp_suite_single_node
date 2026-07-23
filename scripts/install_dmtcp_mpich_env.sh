#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

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
WORKING_MPICH_VER="5.0.0"
WORKING_MPICH_SHA256="e9350e32224283e95311f22134f36c98e3cd1c665d17fae20a6cc92ed3cffe11"

ROOT_PREFIX="${ROOT_PREFIX:-${HOME}/opt}"
BUILD_ROOT="${BUILD_ROOT:-${HOME}/build_dmtcp_mpich}"

AUTOCONF_PREFIX="${ROOT_PREFIX}/autoconf-${AUTOCONF_VER}"
MPICH_PREFIX_VERSIONED="${ROOT_PREFIX}/mpich-${MPICH_VER}-ch3-nemesis-no-libudev"
MPICH_PREFIX="${ROOT_PREFIX}/mpich-dmtcp"

DMTCP_REPO="${DMTCP_REPO:-https://github.com/dmtcp/dmtcp.git}"
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
  make -j"$(nproc)"
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

echo "[6/9] Generating build system and building DMTCP..."

# Some branches/tags include generated files, but using autoreconf keeps the
# procedure consistent for Git checkouts.
autoreconf -fi

preserve_existing_path "${DMTCP_PREFIX_VERSIONED}"

./configure --prefix="${DMTCP_PREFIX_VERSIONED}"

make -j"$(nproc)"
make install

cd "${BUILD_ROOT}"

# An installation made by the old script leaves ${DMTCP_PREFIX} as a real
# directory. Preserve it before creating the generic symlink; ln -sfn cannot
# replace a real directory and would otherwise create the link inside it.
if [ -e "${DMTCP_PREFIX}" ] && [ ! -L "${DMTCP_PREFIX}" ]; then
  LEGACY_DMTCP_BACKUP="${DMTCP_PREFIX}.legacy.$(date +%Y%m%d_%H%M%S)"
  LEGACY_DMTCP_BACKUP_BASE="${LEGACY_DMTCP_BACKUP}"
  LEGACY_DMTCP_BACKUP_INDEX=1

  while [ -e "${LEGACY_DMTCP_BACKUP}" ] || [ -L "${LEGACY_DMTCP_BACKUP}" ]; do
    LEGACY_DMTCP_BACKUP="${LEGACY_DMTCP_BACKUP_BASE}.${LEGACY_DMTCP_BACKUP_INDEX}"
    LEGACY_DMTCP_BACKUP_INDEX=$((LEGACY_DMTCP_BACKUP_INDEX + 1))
  done

  echo "Existing non-symlink DMTCP installation detected:"
  echo "  ${DMTCP_PREFIX}"
  echo "Preserving it as:"
  echo "  ${LEGACY_DMTCP_BACKUP}"
  mv "${DMTCP_PREFIX}" "${LEGACY_DMTCP_BACKUP}"
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
make -j"$(nproc)"

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
  echo "ERROR: MPICH compatibility symlink points to an unexpected location." >&2
  exit 1
fi

# ---------- Reproducibility manifest ----------
echo "[8/9] Writing and validating the build manifest..."

DMTCP_MPICH_MANIFEST="${ROOT_PREFIX}/dmtcp_mpich_single_node_manifest.txt"

{
  echo "profile=DMTCP_MPICH_SINGLE_NODE"
  echo "profile_version=2"
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

if [ "${DMTCP_FULL_COMMIT}" = "${WORKING_DMTCP_COMMIT}" ]; then
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
export DMTCP_SIGCKPT="\${DMTCP_SIGCKPT:-24}"

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
