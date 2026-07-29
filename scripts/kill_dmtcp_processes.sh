#!/usr/bin/env bash

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

set -euo pipefail

# Emergency cleanup for abandoned runs owned by the current user. Matching is
# based on the actual executable basename or process comm value, not arbitrary
# substrings elsewhere in a caller's command line. The helper and its complete
# caller ancestry are always excluded.

CURRENT_USER="${USER:-$(id -un)}"
CURRENT_UID="$(id -u "${CURRENT_USER}")"

matching_processes() {
  python3 - "${CURRENT_UID}" <<'PY'
from pathlib import Path
import os
import re
import sys

uid = int(sys.argv[1])
proc = Path('/proc')
exact = re.compile(
    r'^(?:dmtcp_coordinator|dmtcp_launch|dmtcp_restart|hydra_pmi_proxy|'
    r'mpiexec(?:\.hydra)?|mpirun|bt\.[A-F]\.x|cg\.[A-F]\.x)$'
)

excluded = set()
pid = os.getpid()
while pid > 0 and pid not in excluded:
    excluded.add(pid)
    try:
        raw = (proc / str(pid) / 'stat').read_text()
        right = raw.rfind(')')
        fields = raw[right + 2:].split()
        pid = int(fields[1])
    except (OSError, ValueError, IndexError):
        break

for entry in proc.iterdir():
    if not entry.name.isdigit():
        continue
    pid = int(entry.name)
    if pid in excluded:
        continue
    try:
        if entry.stat().st_uid != uid:
            continue
        comm = (entry / 'comm').read_text(errors='replace').strip()
        raw = (entry / 'cmdline').read_bytes()
    except OSError:
        continue
    argv0 = raw.split(b'\0', 1)[0].decode(errors='replace') if raw else ''
    basename = os.path.basename(argv0)
    if comm.startswith('DMTCP:') or exact.fullmatch(comm) or exact.fullmatch(basename):
        command = raw.replace(b'\0', b' ').decode(errors='replace').strip() or comm
        print(f'{pid}\t{command}')
PY
}

matching_pids() {
  matching_processes | cut -f1
}

signal_matches() {
  local signal_name="$1"
  local -a pids=()
  mapfile -t pids < <(matching_pids)
  [ "${#pids[@]}" -eq 0 ] || kill "-${signal_name}" -- "${pids[@]}" 2>/dev/null || true
}

echo "Matching processes owned by ${CURRENT_USER}:"
if ! matching_processes | sed 's/^/  /' | grep -q .; then
  echo "None"
else
  matching_processes | sed 's/^/  /'
fi

echo
echo "Requesting graceful termination..."
signal_matches TERM
sleep 2

echo "Force-killing any remaining matching processes..."
signal_matches KILL
sleep 1

echo
echo "Remaining matching processes:"
mapfile -t remaining < <(matching_processes)
if [ "${#remaining[@]}" -gt 0 ]; then
  printf '  %s\n' "${remaining[@]}"
  echo "ERROR: Matching DMTCP/MPI/NPB processes remain after cleanup." >&2
  exit 1
fi
echo "None"
