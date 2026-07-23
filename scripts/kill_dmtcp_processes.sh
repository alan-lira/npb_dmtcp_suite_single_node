#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

# Emergency cleanup for abandoned runs owned by the current user.
# This intentionally affects every matching DMTCP/MPI/NPB process owned by the
# user, so do not use it while another experiment is meant to remain active.

PROCESS_PATTERN='dmtcp_coordinator|dmtcp_launch|DMTCP:|hydra|mpiexec|mpirun|bt\.[A-F]\.x|cg\.[A-F]\.x'
CURRENT_USER="${USER:-$(id -un)}"

echo "Matching processes owned by ${CURRENT_USER}:"
pgrep -a -u "${CURRENT_USER}" -f "${PROCESS_PATTERN}" || echo "None"

echo
echo "Requesting graceful termination..."
pkill -TERM -u "${CURRENT_USER}" -f 'dmtcp_coordinator' 2>/dev/null || true
pkill -TERM -u "${CURRENT_USER}" -f 'dmtcp_launch' 2>/dev/null || true
pkill -TERM -u "${CURRENT_USER}" -f 'DMTCP:' 2>/dev/null || true
pkill -TERM -u "${CURRENT_USER}" -f 'hydra' 2>/dev/null || true
pkill -TERM -u "${CURRENT_USER}" -f 'mpiexec' 2>/dev/null || true
pkill -TERM -u "${CURRENT_USER}" -f 'mpirun' 2>/dev/null || true
pkill -TERM -u "${CURRENT_USER}" -f 'bt\.[A-F]\.x' 2>/dev/null || true
pkill -TERM -u "${CURRENT_USER}" -f 'cg\.[A-F]\.x' 2>/dev/null || true

sleep 2

echo "Force-killing any remaining matching processes..."
pkill -KILL -u "${CURRENT_USER}" -f 'dmtcp_coordinator' 2>/dev/null || true
pkill -KILL -u "${CURRENT_USER}" -f 'dmtcp_launch' 2>/dev/null || true
pkill -KILL -u "${CURRENT_USER}" -f 'DMTCP:' 2>/dev/null || true
pkill -KILL -u "${CURRENT_USER}" -f 'hydra' 2>/dev/null || true
pkill -KILL -u "${CURRENT_USER}" -f 'mpiexec' 2>/dev/null || true
pkill -KILL -u "${CURRENT_USER}" -f 'mpirun' 2>/dev/null || true
pkill -KILL -u "${CURRENT_USER}" -f 'bt\.[A-F]\.x' 2>/dev/null || true
pkill -KILL -u "${CURRENT_USER}" -f 'cg\.[A-F]\.x' 2>/dev/null || true

sleep 1

echo
echo "Remaining matching processes:"
pgrep -a -u "${CURRENT_USER}" -f "${PROCESS_PATTERN}" || echo "None"
