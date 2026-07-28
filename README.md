# Single-node NPB + DMTCP checkpoint/restart experiments

This repository runs reproducible single-node checkpoint/restart experiments
with NAS Parallel Benchmarks (NPB-MPI), MPICH, and DMTCP.

The validated software profile is:

- DMTCP commit `6896e12276a9fe449edb0cf206203ce01b19efe6`;
- DMTCP restore-listener backlog patched from `32` to `1024` for the primary
  IPv4 `JServerSocket`, IPv6, Unix-stream, and Unix-seqpacket restore sockets;
- DMTCP stream-buffer refill replaced with a receive-capacity-aware
  nonblocking duplex state machine. It prevents symmetric write/write refill
  deadlocks and temporarily enlarges reconstructed receive buffers when saved
  application data exceeds the kernel default;
- Linux `net.core.somaxconn` verified at `1024` or greater;
- MPICH `5.0.0` using `ch3:nemesis`;
- MPICH embedded hwloc built without libudev;
- NPB-MPI `3.4`, Class `D`.

The supported benchmarks and rank constraints are:

- **BT.D**: the MPI rank count must be a perfect square, such as
  `1, 4, 9, 16, 25, 36, 49, ...`;
- **CG.D**: the MPI rank count must be a power of two, such as
  `1, 2, 4, 8, 16, 32, 64, ...`.

## Validated checkpoint/restart workflow

Every experiment that is actually executed begins by running
`scripts/kill_dmtcp_processes.sh`. This removes abandoned DMTCP, Hydra, MPI,
and NPB processes from an unsuccessful previous run before a new baseline or
checkpoint/restart run starts.

Checkpoint/restart experiments then use this sequence:

1. Start a fresh DMTCP coordinator with `--exit-on-last`.
2. Launch `mpirun` through `dmtcp_launch`.
3. Wait for the configured checkpoint target.
4. Request a checkpoint and verify all checkpoint images and the generated
   restart script.
5. Capture the exact original process tree using PID and `/proc` start time.
6. Capture the TCP, UDP, and Unix endpoints owned by that process tree.
7. Stop the original DMTCP computation and allow the coordinator to exit.
8. Adaptively wait for captured processes to disappear and captured endpoints
   to become reusable.
9. Apply the configured final grace interval only after all endpoints are
   verified clear.
10. Under a suite-wide lock, add the captured original IPv4 TCP listener ports
    to `net.ipv4.ip_local_reserved_ports` so DMTCP's temporary
    `bind(port=0)` restore listener cannot consume one of them.
11. Execute the generated DMTCP restart script without extra coordinator
    arguments.
12. Wait until every expected DMTCP client reports `WorkerState::RUNNING`.
13. If the restore stalls, reports persistent bind errors, or exits before all
    clients are running, preserve per-attempt diagnostics, clean the failed
    restored process tree and endpoints, and retry the same checkpoint while
    keeping the captured ports reserved.
14. After a successful socket restart, restore the previous reserved-port
    setting and release the lock.
15. Continue the restored application, require `Verification = SUCCESSFUL`,
    and create `SUCCESS.marker` atomically.

The runner does not use `--ckpt-open-files` and does not reuse the original
coordinator during restart.

## Repository structure

```text
patches/
  dmtcp-6896e12276a9fe449edb0cf206203ce01b19efe6/
    README.md
    connectionrewirer-backlog-1024.exact.patch
    kernelbufferdrainer-duplex-refill.patch
scripts/
  adaptive_pre_restore_cleanup.py
  restore_port_reservation.py
  build_npb_bt_cg_d.sh
  check_repository.sh
  experiment_config.sh
  install_dmtcp_mpich_env.sh
  install_npb_mpi.sh
  kill_dmtcp_processes.sh
  run_all.sh
  run_one.sh
  summarize_results.py
  verify_single_node_environment.sh

tests/
  test_adaptive_pre_restore_cleanup.py
  test_repository_contract.py
  test_restore_port_reservation.py
  test_restore_retry.py
  test_run_resume.py
  test_summarize_results.py

output/                         # generated; ignored by Git
  binaries/
  results/
```

## 1. Check the repository

From the repository root:

```bash
chmod +x scripts/*.sh scripts/*.py tests/*.py
./scripts/check_repository.sh
```

The checker validates Bash and Python syntax, executable permissions, both
version-specific DMTCP patch assets and their checksums, the current
output-artifact contract, success-marker/resume integration, pre-run cleanup
integration, and the controlled tests under `tests/`.

## 2. Install DMTCP and MPICH

```bash
./scripts/install_dmtcp_mpich_env.sh
```

The installer:

1. installs the required Ubuntu build dependencies;
2. builds local Autoconf `2.72`;
3. checks out the exact DMTCP commit;
4. verifies the checksums of both files in the commit-specific patch bundle;
5. applies `connectionrewirer-backlog-1024.exact.patch`, changing exactly
   four restore-listener paths from backlog `32` to `1024`:

   ```cpp
   jalib::JServerSocket restoreSocket(sockAddr, 0, 1024);
   _real_listen(ip6fd, 1024)
   _real_listen(udsfd, 1024)
   _real_listen(udsseqfd, 1024)
   ```

6. applies `kernelbufferdrainer-duplex-refill.patch` as a strict unified diff
   with `--forward`, zero fuzz, and no interactive patch decisions;
7. verifies the pinned original source checksum, the exact patch checksum,
   and the receive-capacity implementation markers in the patched source;
8. verifies or raises `net.core.somaxconn` to at least `1024`;
9. builds DMTCP and verifies that the installed `libdmtcp_ipc.so` contains
   both the duplex state-machine and receive-capacity implementation markers;
10. builds MPICH `5.0.0` with `ch3:nemesis` and embedded hwloc without libudev;
11. writes a reproducibility manifest and environment helper, including the
    exact patch-file checksum, resulting source checksum, and installed plugin
    checksum.

### Version-specific DMTCP patch bundle

Both local DMTCP modifications are stored together under the exact commit to
which they apply:

```text
patches/dmtcp-6896e12276a9fe449edb0cf206203ce01b19efe6/
```

`connectionrewirer-backlog-1024.exact.patch` is a deliberately small exact
substitution patch. Its four `FROM` values must each occur exactly once and
its four `TO` values must not already exist; otherwise installation stops
without modifying the source. This avoids silently applying the backlog change
to an unexpected DMTCP source layout.

`kernelbufferdrainer-duplex-refill.patch` is a standard unified diff. The installer first verifies the pinned original source checksum, applies the
diff with zero fuzz, and then verifies the resulting source and implementation
markers. During restart, the patch uses `SO_RCVBUF` and, when the normal kernel
limit is insufficient, `SO_RCVBUFFORCE`. The original receive-buffer setting is
restored after the refill completes.

The patch directory name, exact asset checksums, pinned original-source
checksum, and strict application checks prevent either modification from being
reused silently with a different DMTCP revision.

The environment helper is written to:

```text
~/opt/enable_dmtcp_mpich_env.sh
```

### Receive-buffer refill capacity fix

The failure bundle from the 36-rank BT.D run showed five reconstructed TCP
streams with receive queues fixed at `127104` bytes while approximately
`430000` bytes remained queued on each peer. The earlier port reservation
removed `EADDRINUSE`, but the refill could not finish because DMTCP had no room
to echo the saved application data back into those receive queues.

The implementation is a receive-capacity-aware nonblocking duplex state machine.

Runtime verification uses release-stable assertion strings embedded in
`libdmtcp_ipc.so`. It deliberately does not require `JTRACE` text, because
optimized DMTCP builds may compile trace-only messages out even when the
patched implementation is present. The environment helper and manifest
checksums remain part of the verification contract.

The updated patch sizes every reconstructed stream receive buffer from the
amount of data originally drained from that socket, adds a safety margin, and
verifies the effective kernel buffer size before any refill traffic begins. A
clear assertion is produced if the host lacks sufficient privilege to use
`SO_RCVBUFFORCE` when `net.core.rmem_max` is too small.

### Build parallelism

Compilation uses eight parallel jobs by default to avoid memory exhaustion on
machines with many CPU cores:

```bash
BUILD_JOBS=8 ./scripts/install_dmtcp_mpich_env.sh
```

Use a smaller value on a memory-constrained machine:

```bash
BUILD_JOBS=4 ./scripts/install_dmtcp_mpich_env.sh
```

Custom installation/build roots are supported:

```bash
ROOT_PREFIX=/opt/my-dmtcp-stack \
BUILD_ROOT=/scratch/my-dmtcp-build \
BUILD_JOBS=8 \
./scripts/install_dmtcp_mpich_env.sh
```

Use the matching `ENV_FILE` override in later commands when the environment
helper is not at its default path.

## 3. Install NPB-MPI

```bash
./scripts/install_npb_mpi.sh
```

The default source location is:

```text
~/NPB3.4-MPI
```

A different location can be selected with:

```bash
NPB_TARGET=/scratch/NPB3.4-MPI ./scripts/install_npb_mpi.sh
```

Use the same path through `NPB_ROOT` when building the benchmarks.

## 4. Build BT.D and CG.D

```bash
./scripts/build_npb_bt_cg_d.sh
```

Custom example:

```bash
OUTPUT_ROOT=/scratch/npb-dmtcp-output \
NPB_ROOT=/scratch/NPB3.4-MPI \
BENCHMARKS_TEXT="bt cg" \
MPI_RANKS_TEXT="16 25 36" \
./scripts/build_npb_bt_cg_d.sh
```

The rank list is recorded in the build manifest, but a benchmark executable is
not built separately for each rank count.

Verify the active stack and binary linkage:

```bash
./scripts/verify_single_node_environment.sh
```

## 5. Output location

The default generated layout is:

```text
<repository>/output/
├── binaries/
└── results/
    ├── per_run_results.csv
    ├── aggregate_results.csv
    └── <run-name>/
```

Redirect all generated artifacts with one variable:

```bash
OUTPUT_ROOT=/scratch/npb-dmtcp-output ./scripts/run_all.sh
```

`BINARY_ROOT` and `RESULTS_ROOT` can be set independently when required.
Absolute paths are recommended for external locations.

## 6. Run one experiment

### Baseline

```bash
./scripts/run_one.sh <bt|cg> <mpi-ranks> baseline <repetition> \
  [delete-checkpoints|keep-checkpoints]
```

Example:

```bash
./scripts/run_one.sh bt 36 baseline 1 keep-checkpoints
```

### Percentage-target checkpoint/restart

```bash
./scripts/run_one.sh <bt|cg> <mpi-ranks> cr percent \
  <checkpoint-percentage> <repetition> \
  [delete-checkpoints|keep-checkpoints]
```

Example:

```bash
./scripts/run_one.sh bt 36 cr percent 30 1 keep-checkpoints
```

Percentage mode requires at least one matching successful baseline marked by
`SUCCESS.marker`, unless `BASELINE_REFERENCE_SECONDS=<seconds>` is explicitly
provided.

### Direct-delay checkpoint/restart

```bash
./scripts/run_one.sh <bt|cg> <mpi-ranks> cr delay \
  <checkpoint-delay-seconds> <repetition> \
  [delete-checkpoints|keep-checkpoints]
```

Example:

```bash
./scripts/run_one.sh cg 32 cr delay 60 1 keep-checkpoints
```

## 7. Run an experiment matrix

Example for BT.D with 36 ranks, one baseline, one repetition at 30%, 50%, and
80%, retaining checkpoints:

```bash
BENCHMARKS_TEXT="bt" \
MPI_RANKS_TEXT="36" \
BASELINE_REPETITIONS=1 \
CR_REPETITIONS=1 \
CHECKPOINT_PERCENTAGES_TEXT="30 50 80" \
CHECKPOINT_CLEANUP_MODE=keep-checkpoints \
./scripts/run_all.sh
```

The default existing-run policy is:

```text
EXISTING_RUN_POLICY=resume
```

Under `resume`:

- a run directory containing `SUCCESS.marker` is skipped;
- an existing directory without `SUCCESS.marker` is treated as incomplete,
  removed, and rerun;
- missing experiments are executed normally.

This allows the same `run_all.sh` command to continue only the unfinished part
of a matrix after an interruption.

Other policies are:

```text
EXISTING_RUN_POLICY=replace   # rerun every requested experiment
EXISTING_RUN_POLICY=error     # stop if any requested run directory exists
```

`RUN_BASELINE=true` remains safe with the default `resume` policy: successful
baseline repetitions are skipped, while missing or incomplete baseline
repetitions are executed. Use `RUN_BASELINE=false` only when every requested
baseline marker and timing file already exist.

## Restore-port collision protection

The original failure included a case where DMTCP's temporary protected IPv4
restore listener (`fd=823`) selected an original application listener port via
`bind(port=0)`. The restored application later tried to recreate that same
port and received `EADDRINUSE`.

For checkpoint/restart runs, `run_one.sh` now extracts the captured original
IPv4 TCP `LISTEN` ports and temporarily merges them into:

```text
/proc/sys/net/ipv4/ip_local_reserved_ports
```

The runner holds `RESTORE_PORT_RESERVATION_LOCK_FILE` for the complete restore
attempt sequence, including retry cleanup. Explicit application binds can
still recreate their requested ports, while automatic ephemeral allocation
avoids the reserved set. Once every expected DMTCP client reaches `RUNNING`,
the runner restores the exact previous value. The EXIT/INT/TERM cleanup path
also performs restoration. If another administrator changes the sysctl during
the transaction, the helper removes only this run's additions and preserves
the unrelated change.

This protection is enabled by default and requires permission to write the
sysctl (the experiments are normally run as `root`). Disabling it with
`RESTORE_RESERVE_ORIGINAL_TCP_PORTS=false` is intended only for controlled
comparison tests.

## Automatic restore retries

The patched DMTCP IPC plugin removes the deterministic symmetric stream-buffer
refill deadlock observed with CG.D. Independent transient restart failures still
do not immediately fail the experiment: by default, the runner performs up to
three restore attempts using the same set of checkpoint images:

```text
RESTORE_MAX_ATTEMPTS=3
```

After a failed attempt, the runner:

1. preserves the attempt's stdout, stderr, DMTCP client list, socket snapshots,
   process snapshots, and failure reason under `restore_attempts/`;
2. captures the failed restored process tree and its endpoints;
3. stops the failed restore and adaptively waits for those endpoints to become
   reusable;
4. refuses a broad process sweep if exact PID/start-time capture is unavailable;
5. applies `RESTORE_RETRY_FINAL_GRACE_SECONDS` only when another retry will actually be launched;
6. launches the unchanged generated restart script again from the same
   checkpoint images.

A retry does not create a new checkpoint. Checkpoint deletion still occurs only
after the restored NPB application completes successfully and reports
`Verification = SUCCESSFUL`.

The retry mechanism remains a bounded fallback for failures other than the
patched refill deadlock. If every configured attempt fails, the run fails and
retains the checkpoint images and all attempt diagnostics.

When an attempt reaches `RUNNING`, its canonical stdout/stderr files are copied
once for live visibility and refreshed again after the restored application
exits. Final NPB verification therefore reads the complete successful-attempt
output rather than the early `RUNNING` snapshot.

Example with five total attempts:

```bash
RESTORE_MAX_ATTEMPTS=5 \
RESTORE_RETRY_FINAL_GRACE_SECONDS=10 \
./scripts/run_all.sh
```

## Success marker

A successful run contains:

```text
SUCCESS.marker
```

It is created only after:

- the process exits successfully;
- NPB reports `Verification = SUCCESSFUL`;
- all required metrics and the execution summary are written.

Example contents:

```text
status=SUCCESS
run_name=btD_np36_cr_p30_rep1
completed_at=2026-07-26T12:34:56+00:00
npb_verification=SUCCESSFUL
```

`run_status.txt` remains a live/failure diagnostic file. `SUCCESS.marker` is
the authoritative completion marker used by resume and summarization.

## Pre-run process cleanup

Every non-skipped experiment invokes:

```bash
./scripts/kill_dmtcp_processes.sh
```

The output is stored as:

```text
pre_run_cleanup.log
```

The cleanup sends `TERM`, waits, sends `KILL` to remaining matching processes,
and fails the new experiment if any matching DMTCP/MPI/NPB process still
remains.

The cleanup applies to matching processes owned by the current user, while
excluding the cleanup script and its caller ancestry. This prevents a shell or
test harness that merely mentions a matched executable name from being killed.
The suite is intended for one experiment at a time on a single node.

## Main configuration variables

| Variable | Default | Purpose |
|---|---:|---|
| `BENCHMARKS_TEXT` | `bt cg` | Space-separated benchmark matrix |
| `MPI_RANKS_TEXT` | `4` | Space-separated MPI-rank matrix |
| `BASELINE_REPETITIONS` | `3` | Baseline repetitions |
| `CR_REPETITIONS` | `3` | Repetitions per checkpoint target |
| `CHECKPOINT_PERCENTAGES_TEXT` | `25 50 75` | Percentage targets |
| `RUN_BASELINE` | `true` | Process baseline entries in the matrix |
| `EXISTING_RUN_POLICY` | `resume` | Resume, replace, or error |
| `CHECKPOINT_CLEANUP_MODE` | `delete-checkpoints` | Retain or delete checkpoint files |
| `DMTCP_RESTORE_TIMEOUT_SECONDS` | `600` | Timeout applied independently to each restore attempt |
| `RESTORE_MAX_ATTEMPTS` | `3` | Maximum attempts from the same checkpoint |
| `RESTORE_RETRY_FINAL_GRACE_SECONDS` | `10` | Verified-clear grace before an actual retry; skipped after the final failed attempt |
| `RESTORE_RESERVE_ORIGINAL_TCP_PORTS` | `true` | Reserve captured IPv4 TCP listeners during restore |
| `RESTORE_PORT_RESERVATION_LOCK_FILE` | `/run/lock/npb_dmtcp_restore_ports.lock` | Serialize temporary reserved-port changes |
| `RESTORE_PORT_RESERVATION_LOCK_TIMEOUT_SECONDS` | `30` | Maximum lock-acquisition wait |
| `RESTORE_IP_LOCAL_RESERVED_PORTS_PATH` | `/proc/sys/net/ipv4/ip_local_reserved_ports` | Reserved-port sysctl path |
| `CHECKPOINT_FILE_TIMEOUT_SECONDS` | `600` | Checkpoint-image timeout |
| `DMTCP_EXPERIMENT_SIGNAL` | `30` | DMTCP checkpoint signal |
| `DMTCP_PORT_MIN` | `20000` | Random coordinator-port lower bound |
| `DMTCP_PORT_MAX` | `39999` | Random coordinator-port upper bound |
| `PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS` | `180` | Complete adaptive cleanup timeout |
| `PRE_RESTORE_CLEANUP_POLL_SECONDS` | `0.25` | Cleanup polling interval |
| `PRE_RESTORE_FORCE_KILL_AFTER_SECONDS` | `10` | TERM escalation delay |
| `PRE_RESTORE_FORCE_KILL_GRACE_SECONDS` | `5` | KILL escalation grace |
| `PRE_RESTORE_FINAL_GRACE_SECONDS` | `2` | Grace after all endpoints are clear |
| `PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS` | `5` | Cleanup progress interval |
| `RESTORE_BIND_FAILURE_ABORT_SECONDS` | `10` | Persistent bind-error abort threshold |
| `PROGRESS_INTERVAL_SECONDS` | `30` | Application progress interval |
| `RESTORE_PROGRESS_INTERVAL_SECONDS` | `5` | Restore progress interval |

## Current run artifacts

Baseline directories contain only baseline-relevant output, including:

```text
run_metadata.txt
pre_run_cleanup.log
stdout.log
stderr.log
total_seconds.txt
baseline_reference_seconds.txt
npb_verification_successful.txt
execution_summary.txt
run_status.txt
SUCCESS.marker
```

Checkpoint/restart directories additionally contain current checkpoint,
cleanup, restore, size, and overhead metrics, including:

```text
checkpoint_command_seconds.txt
checkpoint_file_wait_seconds.txt
checkpoint_seconds.txt
checkpoint_size_bytes.txt
checkpoint_size_gb.txt
checkpoint_size_gib.txt
checkpoint_mean_per_rank_gb.txt
checkpoint_mean_per_rank_gib.txt
checkpoint_image_count.txt
post_checkpoint_stabilization_seconds.txt
pre_restore_cleanup_seconds.txt
original_shutdown_seconds.txt
pre_restore_endpoint_verification_seconds.txt
pre_restore_final_grace_seconds.txt
restore_reserved_tcp_listener_ports.txt
restore_port_reservation_state.json
restore_port_reservation_prepare.log
restore_port_reservation_release.log
restore_port_reservation_status.txt
dmtcp_restore_seconds.txt
successful_restore_attempt_seconds.txt
restore_attempt_count.txt
restore_retry_count.txt
restore_attempts_summary.tsv
restore_attempts/
post_dmtcp_restore_runtime_seconds.txt
checkpoint_restore_workflow_overhead_seconds.txt
total_dmtcp_related_overhead_seconds.txt
total_dmtcp_related_overhead_percent.txt
residual_dmtcp_runtime_difference_seconds.txt
execution_summary.txt
run_status.txt
SUCCESS.marker
```

This version reads and writes only the current artifact names. Old alias files
and old result-directory naming forms are not generated, resumed, or consumed.

## Result definitions

`total_seconds.txt` is complete elapsed workflow time from initial application
launch until successful completion after restart.

`checkpoint_seconds.txt` measures the checkpoint command plus the wait for all
checkpoint images and the generated restart script.

`pre_restore_cleanup_seconds.txt` measures the complete adaptive cleanup,
including captured-process shutdown, endpoint verification, and the final
verified-clear grace interval.

`dmtcp_restore_seconds.txt` measures the complete restore phase from
preparing the captured-port reservation until the previous reserved-port value
is restored after one attempt reaches all expected DMTCP clients in
`WorkerState::RUNNING`. It includes reservation setup/release, failed-attempt
duration, retry cleanup, and the configured verified-clear retry grace.

`successful_restore_attempt_seconds.txt` measures only the attempt that
successfully reached all expected clients in `WorkerState::RUNNING`.

`restore_attempt_count.txt` records the number of attempts executed, while
`restore_retry_count.txt` records the number of retries. Per-attempt logs and
diagnostics are stored below `restore_attempts/` and summarized in
`restore_attempts_summary.tsv`.

`checkpoint_restore_workflow_overhead_seconds.txt` is:

```text
checkpoint
+ post-checkpoint stabilization
+ adaptive pre-restore cleanup
+ restore
```

`total_dmtcp_related_overhead_seconds.txt` is:

```text
complete checkpoint/restart workflow duration - matching baseline mean
```

`residual_dmtcp_runtime_difference_seconds.txt` is:

```text
total DMTCP-related overhead - measured checkpoint/restore workflow overhead
```

The residual is signed. A positive value means the DMTCP execution was slower
outside the explicitly measured checkpoint/cleanup/restore phases; a negative
value means it was faster over those remaining runtime portions.

## Summaries

Summarize the default results directory:

```bash
./scripts/summarize_results.py
```

Custom directory:

```bash
./scripts/summarize_results.py \
  --results-root /scratch/npb-dmtcp-output/results
```

Only directories containing `SUCCESS.marker` are included. The script writes:

```text
per_run_results.csv
aggregate_results.csv
```

## Tests

Run all repository checks and controlled tests:

```bash
./scripts/check_repository.sh
```

The tests cover:

- PID/start-time-safe adaptive process cleanup;
- TCP, UDP, filesystem Unix, and abstract Unix socket reuse;
- protection against killing an unrelated process after PID/endpoint changes;
- the version-specific DMTCP backlog and duplex-refill patch bundle, patch
  checksums, bounded build jobs, and script contract;
- bounded same-checkpoint restore retry after a controlled first-attempt stall;
- final canonical-log refresh after delayed restored-application output;
- pre-run cleanup, incomplete-run replacement, success-marker creation, and resume skipping;
- marker-based result summarization and rejection of unmarked runs.

## Emergency cleanup

To remove abandoned DMTCP/MPI/NPB processes manually:

```bash
./scripts/kill_dmtcp_processes.sh
```

Do not run it while another experiment owned by the same user is intended to
remain active.
