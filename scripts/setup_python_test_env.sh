#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

PYTHON_TEST_ENV_DIR="${PYTHON_TEST_ENV_DIR:-${REPO_ROOT}/.test-env}"
PYTHON_TEST_BOOTSTRAP="${PYTHON_TEST_BOOTSTRAP:-python3}"
PYTHON_TEST_REQUIREMENTS="${PYTHON_TEST_REQUIREMENTS:-${REPO_ROOT}/requirements-test.txt}"
PRINT_PYTHON=false

usage() {
  cat <<EOF_USAGE
Usage: $0 [--print-python]

Create or update the isolated Python environment used by repository tests.

Environment overrides:
  PYTHON_TEST_ENV_DIR       Environment directory (default: <repo>/.test-env)
  PYTHON_TEST_BOOTSTRAP     Python used to create it (default: python3)
  PYTHON_TEST_REQUIREMENTS  Requirements file (default: requirements-test.txt)
EOF_USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --print-python)
      PRINT_PYTHON=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ ! -f "${PYTHON_TEST_REQUIREMENTS}" ]; then
  printf 'ERROR: Python test requirements file not found: %s\n' \
    "${PYTHON_TEST_REQUIREMENTS}" >&2
  exit 1
fi

if ! command -v "${PYTHON_TEST_BOOTSTRAP}" >/dev/null 2>&1; then
  printf 'ERROR: Python bootstrap executable not found: %s\n' \
    "${PYTHON_TEST_BOOTSTRAP}" >&2
  exit 1
fi

VENV_PYTHON="${PYTHON_TEST_ENV_DIR}/bin/python"
MARKER_FILE="${PYTHON_TEST_ENV_DIR}/.requirements-test.sha256"

if [ ! -x "${VENV_PYTHON}" ]; then
  rm -rf -- "${PYTHON_TEST_ENV_DIR}"
  mkdir -p -- "$(dirname -- "${PYTHON_TEST_ENV_DIR}")"
  printf '[python-test-env] Creating isolated environment at %s\n' \
    "${PYTHON_TEST_ENV_DIR}" >&2
  if ! "${PYTHON_TEST_BOOTSTRAP}" -m venv "${PYTHON_TEST_ENV_DIR}"; then
    cat >&2 <<EOF_ERROR
ERROR: could not create the isolated Python test environment.
Install the Python venv package first (Ubuntu: python3-venv) and retry.
EOF_ERROR
    exit 1
  fi
fi

if ! "${VENV_PYTHON}" -m pip --version >/dev/null 2>&1; then
  printf '[python-test-env] Installing pip with ensurepip.\n' >&2
  if ! "${VENV_PYTHON}" -m ensurepip --upgrade >&2; then
    cat >&2 <<EOF_ERROR
ERROR: pip is unavailable inside ${PYTHON_TEST_ENV_DIR}.
Install python3-venv and python3-pip, remove the environment directory, and retry.
EOF_ERROR
    exit 1
  fi
fi

requirements_sha256="$(${VENV_PYTHON} - "${PYTHON_TEST_REQUIREMENTS}" <<'PY'
from hashlib import sha256
from pathlib import Path
import sys
print(sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
recorded_sha256=""
if [ -f "${MARKER_FILE}" ]; then
  recorded_sha256="$(tr -d '[:space:]' < "${MARKER_FILE}")"
fi

pytest_available=false
if "${VENV_PYTHON}" -c 'import pytest' >/dev/null 2>&1; then
  pytest_available=true
fi

if [ "${recorded_sha256}" != "${requirements_sha256}" ] || \
   [ "${pytest_available}" != true ]; then
  printf '[python-test-env] Installing requirements from %s\n' \
    "${PYTHON_TEST_REQUIREMENTS}" >&2
  PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "${VENV_PYTHON}" -m pip install --requirement "${PYTHON_TEST_REQUIREMENTS}" >&2
  printf '%s\n' "${requirements_sha256}" > "${MARKER_FILE}"
fi

if ! "${VENV_PYTHON}" -c 'import pip, pytest' >/dev/null 2>&1; then
  printf 'ERROR: isolated environment is missing pip or pytest: %s\n' \
    "${PYTHON_TEST_ENV_DIR}" >&2
  exit 1
fi

if [ "${PRINT_PYTHON}" = true ]; then
  printf '%s\n' "${VENV_PYTHON}"
else
  pytest_version="$(${VENV_PYTHON} -c 'import pytest; print(pytest.__version__)')"
  pip_version="$(${VENV_PYTHON} -m pip --version | awk '{print $2}')"
  printf '[OK] Isolated Python test environment: %s\n' "${PYTHON_TEST_ENV_DIR}"
  printf '[OK] pip %s; pytest %s\n' "${pip_version}" "${pytest_version}"
fi
