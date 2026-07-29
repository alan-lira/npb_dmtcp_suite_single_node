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
- NAS Parallel Benchmarks archive `3.4.4` (`NPB3.4-MPI` source tree), Class `D`.

The supported benchmarks and rank constraints are:

- **BT.D**: the MPI rank count must be a perfect square, such as
  `1, 4, 9, 16, 25, 36, 49, ...`;
- **CG.D**: the MPI rank count must be a power of two, such as
  `1, 2, 4, 8, 16, 32, 64, ...`.

## Platform and privilege requirements

The suite targets a Linux single node with `/proc`, `/proc/sys`, Bash, Python 3,
and the standard process/socket inspection utilities used by the diagnostics.
The installation script is Ubuntu-oriented and uses `sudo apt` for build
dependencies.

Checkpoint/restart runs normally require `root` or equivalent privileges because
the restore workflow temporarily updates `net.ipv4.ip_local_reserved_ports`,
`net.core.rmem_max`, and `net.ipv4.tcp_rmem`. Both kernel transactions are
serialized, verified, and restored on success, failure, or signal cleanup. The
suite is designed for one active experiment per user on a node.

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
10. Under a suite-wide lock, transactionally raise `net.core.rmem_max` and
    `net.ipv4.tcp_rmem` to validated restore-time floors so reconstructed TCP
    connections negotiate enough receive-window capacity before refill.
11. Under a separate suite-wide lock, add the captured original IPv4 TCP
    listener ports to `net.ipv4.ip_local_reserved_ports` so DMTCP's temporary
    `bind(port=0)` restore listener cannot consume one of them.
12. Execute the generated DMTCP restart script without extra coordinator
    arguments.
13. Wait until every expected DMTCP client reports `WorkerState::RUNNING`.
14. If the restore stalls, reports persistent bind errors, or exits before all
    clients are running, preserve per-attempt diagnostics, clean the failed
    restored process tree and endpoints, and retry the same checkpoint while
    keeping both restore-scoped kernel transactions active.
15. After a successful socket restart, restore the previous reserved-port and
    TCP receive-window values exactly, then release both locks.
16. Continue the restored application, require `Verification = SUCCESSFUL`,
    and create `SUCCESS.marker` atomically.

The runner does not use `--ckpt-open-files` and does not reuse the original
coordinator during restart.

## Repository structure

<!-- BEGIN REPOSITORY STRUCTURE -->
```text
.gitignore
LICENSE
README.md
patches/
  dmtcp-6896e12276a9fe449edb0cf206203ce01b19efe6/
    README.md
    connectionrewirer-backlog-1024.exact.patch
    kernelbufferdrainer-duplex-refill.patch
scripts/
  adaptive_pre_restore_cleanup.py
  build_npb_bt_cg_d.sh
  check_repository.sh
  experiment_config.sh
  install_dmtcp_mpich_env.sh
  install_npb_mpi.sh
  kill_dmtcp_processes.sh
  restore_port_reservation.py
  restore_tcp_receive_window.py
  run_all.sh
  run_one.sh
  summarize_results.py
  verify_single_node_environment.sh
tests/
  test_adaptive_pre_restore_cleanup.py
  test_dmtcp_patch_application.py
  test_readme_consistency.py
  test_refill_receive_capacity.py
  test_repository_contract.py
  test_restore_port_reservation.py
  test_restore_retry.py
  test_restore_tcp_receive_window.py
  test_run_resume.py
  test_summarize_results.py
output/                         # generated; ignored by Git
  binaries/
  results/
```
<!-- END REPOSITORY STRUCTURE -->

## 1. Check the repository

Ensure the repository scripts and tests are executable before running the
checks:

```bash
chmod +x scripts/*.sh scripts/*.py tests/*.py
```

From the repository root:

```bash
./scripts/check_repository.sh
```

The checker validates Bash and Python syntax, executable permissions, unwanted
IDE/cache artifacts, the version-specific DMTCP patch assets and checksums,
README/repository consistency, current output-artifact names, configuration
integration, and the controlled unit tests.

Two longer process-lifecycle simulations are intentionally executed separately:

```bash
./tests/test_restore_retry.py
./tests/test_run_resume.py
```

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

`kernelbufferdrainer-duplex-refill.patch` is a standard unified diff. The
installer first verifies the pinned original source checksum, applies the
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

Checkpoint images can contain substantial buffered TCP data on both endpoints of
a reconstructed stream. A refill procedure that performs blocking writes before
draining peer data can deadlock when the available receive capacity is smaller
than the saved payload.

The implementation therefore uses a receive-capacity-aware nonblocking duplex
state machine.

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
│   ├── bt.D.x
│   ├── cg.D.x
│   └── build_manifest.txt
└── results/
    ├── <benchmark><class>_np<ranks>_baseline_reference_seconds.txt
    ├── <benchmark><class>_np<ranks>_checkpoint_schedule.tsv
    ├── per_run_results.csv
    ├── aggregate_results.csv
    └── <run-name>/
```

The baseline-reference and checkpoint-schedule files are generated by
`run_all.sh` for each requested benchmark/rank combination. The CSV files are
generated by `summarize_results.py` after the matrix completes.

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

DMTCP creates a temporary protected IPv4 restore listener using `bind(port=0)`.
Without explicit protection, automatic ephemeral allocation could select a port
that a restored application listener must later recreate.

For checkpoint/restart runs, `run_one.sh` extracts the captured original
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

## Restore-scoped TCP receive-window tuning

Some checkpoint states require DMTCP to return more buffered TCP data than the
host's default receive window can accommodate. Because TCP window scaling and
receive capacity are established during connection creation, the required
restore-time floors must be active before reconstructed sockets reconnect.

For checkpoint/restart runs, `run_one.sh` applies this adjustment automatically
immediately before the generated restart script is launched:

```text
net.core.rmem_max floor: 16777216
net.ipv4.tcp_rmem floor: 4096 4194304 16777216
```

These are floors rather than unconditional replacements: a host already
configured with larger values is never lowered during restore. The runner:

1. acquires `RESTORE_TCP_RECEIVE_WINDOW_LOCK_FILE`;
2. captures the exact current values;
3. raises `net.core.rmem_max` before `net.ipv4.tcp_rmem`;
4. verifies the values read back from the kernel;
5. keeps them active through all restore attempts and retry cleanup;
6. restores `net.ipv4.tcp_rmem` and then `net.core.rmem_max` to their exact
   pre-restore values when clients reach `RUNNING`, on failure, or on
   `EXIT`, `INT`, or `TERM` cleanup;
7. verifies restoration before releasing the lock.

The tuning is restore-scoped, so baseline execution and the pre-checkpoint
portion of a checkpoint/restart run retain the host's normal TCP settings. Its
small setup and release cost is included in `dmtcp_restore_seconds.txt`.

This protection is enabled by default and requires permission to write both
sysctls. `RESTORE_TUNE_TCP_RECEIVE_WINDOW=false` is intended only for controlled
comparison or diagnostic testing.

## Automatic restore retries

The patched DMTCP IPC plugin prevents deterministic symmetric stream-buffer
refill deadlocks. Independent transient restart failures still do not immediately
fail the experiment: by default, the runner performs up to three restore attempts
using the same set of checkpoint images:

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

## Configuration reference

### Paths and stack selection

| Variable | Default | Purpose |
|---|---:|---|
| `OUTPUT_ROOT` | `<repository>/output` | Parent directory for generated binaries and results |
| `BINARY_ROOT` | `<OUTPUT_ROOT>/binaries` | Built NPB executables |
| `RESULTS_ROOT` | `<OUTPUT_ROOT>/results` | Run directories, schedules, and summaries |
| `ENV_FILE` | `~/opt/enable_dmtcp_mpich_env.sh` | Installed DMTCP/MPICH environment helper |
| `NPB_ROOT` | `~/NPB3.4-MPI` | NPB-MPI source tree |
| `NPB_CLASS` | `D` | NPB problem class |
| `REQUIRE_WORKING_STACK` | `true` | Reject a stack that does not match the pinned profile |

The `WORKING_DMTCP_*` and `WORKING_MPICH_*` values in
`scripts/experiment_config.sh` are reproducibility-contract constants. They
should be changed only together with the installer, patch bundle, verifier, and
contract tests.

### Experiment matrix and run policy

| Variable | Default | Purpose |
|---|---:|---|
| `BENCHMARKS_TEXT` | `bt cg` | Space-separated benchmark matrix |
| `MPI_RANKS_TEXT` | `4` | Space-separated MPI-rank matrix |
| `REPETITIONS` | unset | Optional shorthand that sets both repetition counts |
| `BASELINE_REPETITIONS` | `3` | Baseline repetitions |
| `CR_REPETITIONS` | `3` | Repetitions per checkpoint target |
| `CHECKPOINT_PERCENTAGES_TEXT` | `25 50 75` | Percentage targets used by `run_all.sh` |
| `RUN_BASELINE` | `true` | Process baseline entries in the matrix |
| `EXISTING_RUN_POLICY` | `resume` | `resume`, `replace`, or `error` |
| `CHECKPOINT_CLEANUP_MODE` | `delete-checkpoints` | `delete-checkpoints` or `keep-checkpoints` |
| `BASELINE_REFERENCE_SECONDS` | unset | Explicit positive baseline for percentage mode |

### Coordinator, checkpoint, and progress controls

| Variable | Default | Purpose |
|---|---:|---|
| `DMTCP_COORD_PORT` | automatic | Force one coordinator port instead of random selection |
| `DMTCP_PORT_MIN` | `20000` | Random coordinator-port lower bound |
| `DMTCP_PORT_MAX` | `39999` | Random coordinator-port upper bound |
| `DMTCP_EXPERIMENT_SIGNAL` | `30` | Signal used by DMTCP for checkpointing |
| `COORDINATOR_START_TIMEOUT_SECONDS` | `30` | Fresh-coordinator readiness timeout |
| `CHECKPOINT_FILE_TIMEOUT_SECONDS` | `600` | Checkpoint-image and restart-script timeout |
| `POST_CHECKPOINT_STABILIZATION_SECONDS` | `2` | Grace after checkpoint artifacts are complete |
| `DMTCP_RESTORE_TIMEOUT_SECONDS` | `600` | Timeout applied independently to each restore attempt |
| `PROGRESS_INTERVAL_SECONDS` | `30` | Application progress-report interval |
| `RESTORE_PROGRESS_INTERVAL_SECONDS` | `5` | Restore-state progress-report interval |

`COORDINATOR_LIFECYCLE` is fixed to `fresh` for the validated workflow. The
generated restart script is executed without additional coordinator arguments.

### Adaptive cleanup and restore retries

| Variable | Default | Purpose |
|---|---:|---|
| `PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS` | `180` | Complete adaptive cleanup timeout |
| `PRE_RESTORE_CLEANUP_POLL_SECONDS` | `0.25` | Cleanup polling interval |
| `PRE_RESTORE_FORCE_KILL_AFTER_SECONDS` | `10` | Delay before TERM escalation |
| `PRE_RESTORE_FORCE_KILL_GRACE_SECONDS` | `5` | Delay between TERM and KILL escalation |
| `PRE_RESTORE_FINAL_GRACE_SECONDS` | `2` | Grace after every captured endpoint is reusable |
| `PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS` | `5` | Cleanup progress-report interval |
| `RESTORE_BIND_FAILURE_ABORT_SECONDS` | `10` | Persistent bind-error early-abort threshold |
| `RESTORE_MAX_ATTEMPTS` | `3` | Maximum attempts from the same checkpoint |
| `RESTORE_RETRY_FINAL_GRACE_SECONDS` | `10` | Verified-clear grace before a real retry; skipped after the final failed attempt |

### Restore-scoped kernel transactions

| Variable | Default | Purpose |
|---|---:|---|
| `RESTORE_RESERVE_ORIGINAL_TCP_PORTS` | `true` | Reserve captured IPv4 TCP listeners during restore |
| `RESTORE_PORT_RESERVATION_LOCK_FILE` | `/run/lock/npb_dmtcp_restore_ports.lock` | Serialize temporary reserved-port changes |
| `RESTORE_PORT_RESERVATION_LOCK_TIMEOUT_SECONDS` | `30` | Maximum reserved-port lock wait |
| `RESTORE_IP_LOCAL_RESERVED_PORTS_PATH` | `/proc/sys/net/ipv4/ip_local_reserved_ports` | Reserved-port sysctl path |
| `RESTORE_TUNE_TCP_RECEIVE_WINDOW` | `true` | Apply restore-scoped TCP receive-window floors |
| `RESTORE_TCP_RECEIVE_WINDOW_LOCK_FILE` | `/run/lock/npb_dmtcp_restore_tcp_receive_window.lock` | Serialize receive-window changes |
| `RESTORE_TCP_RECEIVE_WINDOW_LOCK_TIMEOUT_SECONDS` | `30` | Maximum receive-window lock wait |
| `RESTORE_NET_CORE_RMEM_MAX` | `16777216` | Restore-time `net.core.rmem_max` floor |
| `RESTORE_NET_IPV4_TCP_RMEM` | `4096 4194304 16777216` | Restore-time `net.ipv4.tcp_rmem` floors |
| `RESTORE_NET_CORE_RMEM_MAX_PATH` | `/proc/sys/net/core/rmem_max` | Testable `rmem_max` sysctl path |
| `RESTORE_NET_IPV4_TCP_RMEM_PATH` | `/proc/sys/net/ipv4/tcp_rmem` | Testable `tcp_rmem` sysctl path |

### Installation and build overrides

| Variable | Default | Used by |
|---|---:|---|
| `ROOT_PREFIX` | `~/opt` | DMTCP/MPICH installer |
| `BUILD_ROOT` | `~/build_dmtcp_mpich` | DMTCP/MPICH installer |
| `BUILD_JOBS` | `8` | Bounded parallel build jobs |
| `AUTOCONF_VER` | `2.72` | DMTCP/MPICH installer |
| `MPICH_VER` | `5.0.0` | DMTCP/MPICH installer; pinned profile requires this version |
| `DMTCP_REF` | pinned commit | DMTCP/MPICH installer; alternatives are for controlled comparisons |
| `DMTCP_REPO` | official DMTCP Git repository | DMTCP source location |
| `NPB_VERSION` | `3.4.4` | NPB installer archive version |
| `NPB_URL` | official archive URL | NPB installer source URL |
| `NPB_TARGET` | `~/NPB3.4-MPI` | NPB installer destination |

## Current output artifacts

### Matrix-level files

`run_all.sh` and `summarize_results.py` write these directly below
`RESULTS_ROOT`:

```text
<benchmark><class>_np<ranks>_baseline_reference_seconds.txt
<benchmark><class>_np<ranks>_checkpoint_schedule.tsv
per_run_results.csv
aggregate_results.csv
```

### Common per-run files

Successful baseline and checkpoint/restart directories contain:

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

`SUCCESS.marker` is authoritative. A directory without it is incomplete even if
`run_status.txt` contains an intermediate state.

### Checkpoint/restart files

Checkpoint/restart directories additionally contain stable identity,
checkpoint, cleanup, restore, and overhead artifacts:

```text
checkpoint_mode.txt
checkpoint_percentage.txt
checkpoint_baseline_seconds.txt
checkpoint_target_seconds.txt
dmtcp_signal.txt
coordinator_lifecycle.txt
dmtcp_commit.txt
dmtcp_restore_listen_backlog.txt
kernel_net_core_somaxconn.txt
mpich_version.txt
mpich_device.txt
dmtcp_coord_port.txt
coordinator.log
pre_checkpoint_runtime_seconds.txt
stdout_before_ckpt.log
stderr_before_ckpt.log
dmtcp_clients_before_checkpoint.txt
dmtcp_list_before_checkpoint.txt
checkpoint_command_seconds.txt
checkpoint_file_wait_seconds.txt
checkpoint_seconds.txt
checkpoint_image_count.txt
checkpoint_size_bytes.txt
checkpoint_size_gb.txt
checkpoint_size_gib.txt
checkpoint_mean_per_rank_gb.txt
checkpoint_mean_per_rank_gib.txt
post_checkpoint_stabilization_seconds.txt
pre_restore_capture.log
pre_restore_captured_state.json
pre_restore_captured_processes.tsv
pre_restore_captured_sockets.tsv
pre_restore_cleanup.log
pre_restore_cleanup_status.txt
pre_restore_cleanup_seconds.txt
original_shutdown_seconds.txt
pre_restore_endpoint_verification_seconds.txt
pre_restore_final_grace_seconds.txt
pre_restore_cleanup_removed_unix_sockets.txt
restore_reserved_tcp_listener_ports.txt
restore_port_reservation_state.json
restore_port_reservation_prepare.log
restore_port_reservation_release.log
restore_port_reservation_status.txt
restore_port_reservation_original_value.txt
restore_port_reservation_applied_value.txt
restore_port_reservation_released_value.txt
restore_tcp_receive_window_state.json
restore_tcp_receive_window_prepare.log
restore_tcp_receive_window_release.log
restore_tcp_receive_window_status.txt
restore_tcp_receive_window_original_rmem_max.txt
restore_tcp_receive_window_original_tcp_rmem.txt
restore_tcp_receive_window_applied_rmem_max.txt
restore_tcp_receive_window_applied_tcp_rmem.txt
restore_tcp_receive_window_released_rmem_max.txt
restore_tcp_receive_window_released_tcp_rmem.txt
restore_attempts_summary.tsv
restore_attempts/
dmtcp_restore_marker_found.txt
dmtcp_clients_running_after_restore.txt
dmtcp_list_after_restore_latest.txt
dmtcp_list_after_restore_confirmed.txt
stdout_after_restore.log
stderr_after_restore.log
dmtcp_restore_seconds.txt
successful_restore_attempt_seconds.txt
restore_attempt_count.txt
restore_retry_count.txt
post_dmtcp_restore_runtime_seconds.txt
checkpoint_restore_workflow_overhead_seconds.txt
total_dmtcp_related_overhead_seconds.txt
total_dmtcp_related_overhead_percent.txt
residual_dmtcp_runtime_difference_seconds.txt
```

Each `restore_attempts/attempt_NN/` directory preserves the attempt status,
duration, stdout/stderr, DMTCP state, process/socket diagnostics, bind-failure
tracking, and exact cleanup capture for a failed attempt. Additional
`<failure-prefix>_diagnostics.txt`, `<failure-prefix>_processes.txt`,
`<failure-prefix>_inet_sockets.txt`, and
`<failure-prefix>_unix_sockets.txt` files are generated only on relevant failure
paths.

With `keep-checkpoints`, `ckpt_*.dmtcp` files and the generated
`dmtcp_restart_script*.sh` remain in the run directory. With
`delete-checkpoints`, successful cleanup records removed artifacts in
`deleted_checkpoint_artifacts.txt`.

This version reads and writes only the current artifact names. Obsolete aliases
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
preparing the restore-scoped TCP receive-window transaction through restoring
both the previous reserved-port value and the exact previous TCP receive-window
sysctls after one attempt reaches all expected DMTCP clients in
`WorkerState::RUNNING`. It includes both transaction setup/release operations,
failed-attempt duration, retry cleanup, and the configured verified-clear retry
grace.

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

Run the repository checker and its controlled unit tests:

```bash
./scripts/check_repository.sh
```

Then run the two longer process-lifecycle simulations:

```bash
./tests/test_restore_retry.py
./tests/test_run_resume.py
```

The test suite covers:

- README structure, configuration, artifact, and test-command consistency;
- PID/start-time-safe adaptive process cleanup;
- TCP, UDP, filesystem Unix, and abstract Unix socket reuse;
- protection against killing an unrelated process after PID/endpoint changes;
- strict application of the version-specific DMTCP backlog and duplex-refill
  patches, including checksums and receive-capacity markers;
- bounded installer build parallelism and pinned-stack contracts;
- transactional reserved-port and TCP receive-window setup/restoration;
- space- and tab-separated `tcp_rmem` read-back equivalence;
- bounded same-checkpoint restore retry after a controlled first-attempt stall;
- final canonical-log refresh after delayed restored-application output;
- pre-run cleanup, incomplete-run replacement, success-marker creation, and
  resume skipping;
- marker-based result summarization and rejection of unmarked runs.

## Emergency cleanup

To remove abandoned DMTCP/MPI/NPB processes manually:

```bash
./scripts/kill_dmtcp_processes.sh
```

Do not run it while another experiment owned by the same user is intended to
remain active.
