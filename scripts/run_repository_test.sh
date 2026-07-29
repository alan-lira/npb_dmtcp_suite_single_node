#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_PYTHON="$("${SCRIPT_DIR}/setup_python_test_env.sh" --print-python)"

if [ "$#" -eq 0 ]; then
  set -- "${SCRIPT_DIR}/../tests"
fi

export PYTHONDONTWRITEBYTECODE=1
exec "${TEST_PYTHON}" -m pytest -p no:cacheprovider "$@"
