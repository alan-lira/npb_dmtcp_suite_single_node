#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

failed=0

for script in "${SCRIPT_DIR}"/*.sh; do
  if bash -n "${script}"; then
    printf '[OK] bash syntax: %s\n' "${script#${REPO_ROOT}/}"
  else
    failed=1
  fi

done

# bash -n does not evaluate parameter expansions, so source the shared
# configuration once to catch runtime errors such as an invalid ${...}
# substitution before any build or experiment is started.
if (
  set -euo pipefail
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/experiment_config.sh"
  : "${REPO_ROOT}" "${OUTPUT_ROOT}" "${BINARY_ROOT}" "${RESULTS_ROOT}"
); then
  printf '[OK] runtime load: scripts/experiment_config.sh\n'
else
  printf '[ERROR] runtime load failed: scripts/experiment_config.sh\n' >&2
  failed=1
fi

if python3 -m py_compile "${SCRIPT_DIR}/summarize_results.py"; then
  printf '[OK] Python syntax: scripts/summarize_results.py\n'
else
  failed=1
fi

for executable in "${SCRIPT_DIR}"/*.sh "${SCRIPT_DIR}/summarize_results.py"; do
  if [ -x "${executable}" ]; then
    printf '[OK] executable: %s\n' "${executable#${REPO_ROOT}/}"
  else
    printf '[ERROR] not executable: %s\n' "${executable#${REPO_ROOT}/}" >&2
    failed=1
  fi
done

stale_pattern='00_build_npb|01_run_all|install_dmtcp_mpich_working_env|old_run_one\.sh'
if grep -RInE "${stale_pattern}" \
    "${REPO_ROOT}/README.md" "${SCRIPT_DIR}" \
    --exclude='check_repository.sh'; then
  printf '[ERROR] stale script-name references found.\n' >&2
  failed=1
else
  printf '[OK] no stale script-name references\n'
fi

if [ -d "${REPO_ROOT}/.idea" ]; then
  printf '[ERROR] .idea/ should not be committed.\n' >&2
  failed=1
else
  printf '[OK] no committed .idea directory\n'
fi

exit "${failed}"
