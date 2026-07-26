# Single-node NPB + DMTCP checkpoint/restart experiments

This repository runs reproducible single-node checkpoint/restart experiments
with DMTCP, MPICH, and the NAS Parallel Benchmarks.

Supported defaults:

- **BT, Class D** — MPI ranks must be a perfect square: `1, 4, 9, 16, 25, ...`;
- **CG, Class D** — MPI ranks must be a power of two: `1, 2, 4, 8, 16, ...`.

The checkpoint/restart path considers the following sequence:

1. Start a fresh coordinator with `--exit-on-last`;
2. Launch `mpirun` through `dmtcp_launch`;
3. Request the checkpoint;
4. Wait for all checkpoint images and the generated restart script;
5. Capture the exact original process tree using PID and `/proc` start time;
6. Capture the TCP, UDP, and Unix socket endpoints owned by that tree;
7. Kill the original DMTCP computation and let the coordinator exit;
8. Adaptively wait for the captured processes to disappear and for every captured endpoint to become reusable;
9. Apply only a short final grace delay after the resources are verified clear;
10. Execute the generated restart script without extra coordinator arguments;
11. Wait until every DMTCP client reports `WorkerState::RUNNING`;
12. Wait for NPB completion and verify `Verification = SUCCESSFUL`.

The runner does not use `--ckpt-open-files` and does not reuse the original
coordinator during restart.

### Repository structure

```text
scripts/
  install_dmtcp_mpich_env.sh
  install_npb_mpi.sh
  build_npb_bt_cg_d.sh
  verify_single_node_environment.sh
  run_one.sh
  run_all.sh
  adaptive_pre_restore_cleanup.py
  summarize_results.py
  kill_dmtcp_processes.sh
  check_repository.sh
output/                         # Generated; ignored by Git
  binaries/
  results/
```

### 1. Prepare the repository

From the repository root:

```bash
chmod +x scripts/*.sh scripts/*.py tests/*.py
./scripts/check_repository.sh
```

### 2. Install DMTCP and MPICH

```bash
./scripts/install_dmtcp_mpich_env.sh
```

The installer writes the environment helper to:

```text
~/opt/enable_dmtcp_mpich_env.sh
```

The generated helper and the experiment configuration both default to DMTCP
checkpoint signal `30`. Individual experiment commands may override it with
`DMTCP_EXPERIMENT_SIGNAL=<signal>`.

The default build and installation locations can be changed:

```bash
ROOT_PREFIX=/opt/my-dmtcp-stack \
BUILD_ROOT=/scratch/my-dmtcp-build \
./scripts/install_dmtcp_mpich_env.sh
```

Use the same `ENV_FILE` override in later commands when `ROOT_PREFIX` is
changed.

### 3. Download NPB-MPI

```bash
./scripts/install_npb_mpi.sh
```

Default source path:

```text
~/NPB3.4-MPI
```

Custom source path:

```bash
NPB_TARGET=/scratch/NPB3.4-MPI ./scripts/install_npb_mpi.sh
```

Use the matching `NPB_ROOT` value when building.


### 4. Choose the output path

By default, all generated repository artifacts are stored outside `scripts/`,
under the repository-root `output/` directory:

```text
<repository-root>/output/
├── binaries/
└── results/
    └── <run-name>/
```

The default output root is the repository-local `output/` directory and does
not require an environment-variable override:

```text
<repository-root>/output/
```

All generated repository artifacts can instead be redirected with **one
variable**:

```bash
OUTPUT_ROOT=/scratch/npb-dmtcp-output
```

Its layout is:

```text
$OUTPUT_ROOT/binaries/
$OUTPUT_ROOT/results/<run-name>/
```

Each run directory contains logs, metrics, DMTCP restart scripts, and, when
`keep-checkpoints` is selected, the checkpoint files themselves.

To use the default repository-local output path for one command:

```bash
./scripts/run_all.sh
```

To use a custom output path for the same command:

```bash
OUTPUT_ROOT=/scratch/npb-dmtcp-output \
./scripts/run_all.sh
```

To use the default repository-local output path for multiple commands, run
them normally:

```bash
./scripts/build_npb_bt_cg_d.sh
./scripts/verify_single_node_environment.sh
./scripts/run_all.sh
```

To use the same custom output path for multiple commands in the current shell,
export `OUTPUT_ROOT` first and then run the same commands:

```bash
export OUTPUT_ROOT=/scratch/npb-dmtcp-output

./scripts/build_npb_bt_cg_d.sh
./scripts/verify_single_node_environment.sh
./scripts/run_all.sh
```

`BINARY_ROOT` and `RESULTS_ROOT` may be overridden separately when needed:

```bash
BINARY_ROOT=/opt/npb-binaries \
RESULTS_ROOT=/scratch/npb-results \
./scripts/run_one.sh bt 25 cr delay 60 1 keep-checkpoints
```

Use absolute paths for external output locations.

When no output-path variables are set, the default generated paths are:

```text
<repository-root>/output/binaries/
<repository-root>/output/results/
```

The repository-root `.gitignore` file should contain:

```gitignore
/output/
```

### 5. Build BT.D and CG.D

Default output location:

```bash
./scripts/build_npb_bt_cg_d.sh
```

Custom output location:

```bash
OUTPUT_ROOT=/scratch/npb-dmtcp-output \
NPB_ROOT=/scratch/NPB3.4-MPI \
./scripts/build_npb_bt_cg_d.sh
```

Then verify the environment and binary linkage.

With the default repository-local output path:

```bash
./scripts/verify_single_node_environment.sh
```

With a custom output path, use the same `OUTPUT_ROOT` value used during the build:

```bash
OUTPUT_ROOT=/scratch/npb-dmtcp-output \
./scripts/verify_single_node_environment.sh
```

### 6. Run a single experiment

Baseline syntax:

```bash
./scripts/run_one.sh <bt|cg> <mpi-ranks> baseline <rep> \
  [delete-checkpoints|keep-checkpoints]
```

Checkpoint/restart runs support two mutually exclusive target modes.

Percentage mode:

```bash
./scripts/run_one.sh <bt|cg> <mpi-ranks> cr percent \
  <checkpoint-percent> <rep> \
  [delete-checkpoints|keep-checkpoints]
```

Direct-delay mode:

```bash
./scripts/run_one.sh <bt|cg> <mpi-ranks> cr delay \
  <checkpoint-delay-seconds> <rep> \
  [delete-checkpoints|keep-checkpoints]
```

BT.D baseline:

```bash
./scripts/run_one.sh bt 25 baseline 1 keep-checkpoints
```

BT.D checkpoint/restart at 10% of the matching baseline mean:

```bash
./scripts/run_one.sh bt 25 cr percent 10 1 keep-checkpoints
```

Percentage mode requires at least one successful matching baseline run in the
configured results directory. The script calculates the absolute checkpoint
delay as:

```text
checkpoint delay = baseline mean × checkpoint percentage / 100
```

An explicit baseline value may be supplied instead of reading previous baseline
results:

```bash
BASELINE_REFERENCE_SECONDS=1373.779475573 \
./scripts/run_one.sh bt 25 cr percent 10 1 keep-checkpoints
```

BT.D checkpoint/restart with a direct 60-second delay:

```bash
./scripts/run_one.sh bt 25 cr delay 60 1 keep-checkpoints
```

CG.D checkpoint/restart with a direct 60-second delay:

```bash
./scripts/run_one.sh cg 8 cr delay 60 1 keep-checkpoints
```

With the default repository-local output path:

```bash
./scripts/run_one.sh bt 25 cr delay 60 1 keep-checkpoints
```

With a custom output path:

```bash
OUTPUT_ROOT=/scratch/npb-dmtcp-output \
./scripts/run_one.sh bt 25 cr delay 60 1 keep-checkpoints
```

The `percent` and `delay` modes cannot be combined. Percentage-mode run
directories use the percentage, for example `btD_np25_cr_p10_rep1`.
Direct-delay run directories use the absolute delay, for example
`btD_np25_cr_t60_rep1`.


### 7. Run the configured experiment matrix

`scripts/run_all.sh` executes a matrix of baseline and checkpoint/restart
experiments. The default matrix is defined in
`scripts/experiment_config.sh`:

```bash
BENCHMARKS_TEXT="bt cg"
MPI_RANKS_TEXT="4"
BASELINE_REPETITIONS="3"
CR_REPETITIONS="3"
CHECKPOINT_PERCENTAGES_TEXT="25 50 75"
NPB_CLASS="D"
DMTCP_EXPERIMENT_SIGNAL="30"
PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS="180"
PRE_RESTORE_CLEANUP_POLL_SECONDS="0.25"
PRE_RESTORE_FORCE_KILL_AFTER_SECONDS="10"
PRE_RESTORE_FORCE_KILL_GRACE_SECONDS="5"
PRE_RESTORE_FINAL_GRACE_SECONDS="2"
PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS="5"
RESTORE_BIND_FAILURE_ABORT_SECONDS="10"
```

`BASELINE_REPETITIONS` and `CR_REPETITIONS` are counts, not lists of
repetition identifiers. A value of `1` runs one repetition, a value of `2`
runs repetitions `1` and `2`, and a value of `3` runs repetitions `1`, `2`,
and `3`. The repetition number remains part of each run-directory name.

These settings mean that the suite will:

- run both the **BT.D** and **CG.D** benchmarks;
- use **4 MPI ranks** for each benchmark;
- execute **3 baseline repetitions** (`rep1` through `rep3`) for each benchmark;
- calculate a separate mean baseline duration for BT.D and CG.D;
- request checkpoints at **25%, 50%, and 75%** of the corresponding baseline
  mean;
- execute **3 checkpoint/restart repetitions** (`rep1` through `rep3`) for each checkpoint percentage;
- use adaptive process and socket cleanup with a complete default timeout of **180 seconds**;
- apply a **2-second** final grace only after all captured resources are verified clear;
- abort restore early when bind failures persist for **10 seconds**;
- use signal **30** as the DMTCP checkpoint signal.

For each benchmark and MPI-rank combination, the suite follows this order:

```text
1. Run all configured baseline repetitions.
2. Verify the successful baseline runs.
3. Calculate their mean duration.
4. Convert each configured checkpoint percentage into an absolute delay:

   checkpoint delay = baseline mean × checkpoint percentage / 100

5. Run all configured checkpoint/restart repetitions for each percentage.
6. Record checkpoint, restore, storage, runtime, and overhead metrics.
```

With the default configuration, the matrix expands to:

```text
BT.D with 4 MPI ranks:
  3 baseline runs
  3 checkpoint percentages × 3 repetitions = 9 checkpoint/restart runs
  Total: 12 runs

CG.D with 4 MPI ranks:
  3 baseline runs
  3 checkpoint percentages × 3 repetitions = 9 checkpoint/restart runs
  Total: 12 runs

Complete default matrix:
  6 baseline runs
  18 checkpoint/restart runs
  Total: 24 runs
```

Each checkpoint percentage is calculated from the baseline mean of the same
benchmark, NPB class, and MPI-rank count. For example, the BT.D baseline mean
is not used to schedule a CG.D checkpoint.

The configured MPI-rank values must be valid for every selected benchmark:

- BT requires a perfect-square rank count: `1, 4, 9, 16, 25, ...`;
- CG requires a power-of-two rank count: `1, 2, 4, 8, 16, ...`.

When both `bt` and `cg` are selected, values such as `1`, `4`, and `16` are
valid for both benchmarks.

#### Small validation

The following command performs a minimal validation using the default
repository-local output path:

```bash
BENCHMARKS_TEXT="bt" \
MPI_RANKS_TEXT="25" \
BASELINE_REPETITIONS="1" \
CR_REPETITIONS="1" \
CHECKPOINT_PERCENTAGES_TEXT="10" \
CHECKPOINT_CLEANUP_MODE="keep-checkpoints" \
./scripts/run_all.sh
```

This command executes exactly two runs:

```text
1. One BT.D baseline run with 25 MPI ranks.
2. One BT.D checkpoint/restart run with the checkpoint requested at 10% of
   the measured baseline duration.
```

For example, if the baseline duration is `750` seconds, the checkpoint target
will be:

```text
750 × 10 / 100 = 75 seconds after launch
```

The same validation can be executed with a custom output path:

```bash
OUTPUT_ROOT=/scratch/npb-dmtcp-output \
BENCHMARKS_TEXT="bt" \
MPI_RANKS_TEXT="25" \
BASELINE_REPETITIONS="1" \
CR_REPETITIONS="1" \
CHECKPOINT_PERCENTAGES_TEXT="10" \
CHECKPOINT_CLEANUP_MODE="keep-checkpoints" \
./scripts/run_all.sh
```

The environment-variable values placed before `./scripts/run_all.sh` override
the defaults only for that command. They do not modify
`scripts/experiment_config.sh`.

When the same count should be used for both kinds of execution, the shorthand
`REPETITIONS` may be used instead:

```bash
REPETITIONS=2 ./scripts/run_all.sh
```

This runs baseline repetitions `1` and `2`, followed by checkpoint/restart
repetitions `1` and `2` for every configured checkpoint percentage.

#### Full configured matrix

Run the complete matrix currently defined in
`scripts/experiment_config.sh`:

```bash
./scripts/run_all.sh
```

The suite always runs the required baseline repetitions before their
percentage-based checkpoint/restart experiments. A checkpoint/restart run is
not started when no successful matching baseline duration is available.


### Execution messages

A checkpoint/restart execution reports each phase explicitly:

```text
[coordinator] Starting a fresh DMTCP coordinator...
[run] Launching BT.D with 25 MPI ranks under DMTCP.
[checkpoint] Detected 27 DMTCP clients; creating checkpoint images now.
[checkpoint] Checkpoint recorded successfully at ...
[checkpoint] Checkpoint storage: ... GB total | ... GB mean per rank.
[cleanup] Capturing the exact original process tree and its TCP, UDP, and Unix socket endpoints.
[shutdown] Requesting DMTCP client termination...
[cleanup] Waiting adaptively for captured processes and endpoints to become safely reusable.
[adaptive-cleanup] All captured processes have disappeared.
[adaptive-cleanup] All captured socket endpoints are reusable.
[cleanup] Adaptive pre-restore cleanup completed in ...
[restore] Restoring checkpoints using script: ...
[restore] Progress: 27/27 clients RUNNING.
[restore] Restore complete; step took ... seconds.
[run] Restored application is still running...
[run] Still running; elapsed since latest restore: ... | since initial launch: ...
[complete] NPB verification was SUCCESSFUL.
```

### Adaptive pre-restore cleanup

Before terminating the checkpointed computation, `run_one.sh` calls
`adaptive_pre_restore_cleanup.py capture`. The capture file records every
process in the original application/coordinator tree as a `(PID, start time)`
identity and records the socket inodes and endpoints referenced by those exact
processes. A reused PID is therefore never treated as the original process.

After `dmtcp_command --kill`, the cleanup helper waits for the captured
identities to disappear. If necessary, it sends `TERM` and later `KILL` only to
identities whose PID and start time still match the capture. Linux pidfds are
used for escalation so a PID-reuse race cannot redirect the signal after the
identity check. The helper never signals a process merely because that process
owns a conflicting endpoint.

For TCP and UDP endpoints, the helper waits until the captured local address and
port can be rebound. For Unix-domain endpoints, it verifies abstract names and
filesystem paths. A filesystem Unix socket is removed only when it is still a
socket, is owned by the current user, and its filesystem device/inode matches
the file captured for this run. A replaced path or an endpoint owned by an
unrelated process causes the run to fail before the generated restart script is
launched. Reports are written as:

```text
pre_restore_captured_state.json
pre_restore_captured_processes.tsv
pre_restore_captured_sockets.tsv
pre_restore_capture.log
pre_restore_cleanup.log
pre_restore_cleanup_status.txt
pre_restore_cleanup_failure.txt          # only on failure
pre_restore_cleanup_removed_unix_sockets.txt
```

During restore, `stderr_after_restore.log` is checked continuously. Persistent
`Address already in use` or `Bind failed` messages trigger an early failure and
diagnostic collection after `RESTORE_BIND_FAILURE_ABORT_SECONDS`, rather than
waiting for the complete restore timeout.

### Measurements

Every successful run contains `execution_summary.txt`. For a
checkpoint/restart execution with a matching baseline, the summary has the
following form:

```text
Total duration: X seconds
Size of checkpoints: Y1 GB total | Y2 GB mean per application rank
Time required for the checkpoint step: X seconds
Time required for the restore step: X seconds
DMTCP checkpoint/restore workflow overhead: X seconds
  Included phases: checkpoint X + post-checkpoint stabilization X + adaptive pre-restore cleanup X + restore X seconds
  Adaptive cleanup detail: captured-process shutdown X + endpoint verification X + final verified-clear grace X seconds
Total DMTCP-related overhead: X seconds (... compared with baseline mean ...; complete DMTCP execution was X seconds faster/slower than the baseline)
Residual DMTCP runtime difference: X seconds (execution outside the checkpoint/restore workflow was X seconds faster/slower than the baseline)
```

A baseline execution reports only its total duration and explicitly marks the
DMTCP-specific measurements as unavailable:

```text
Total duration: X seconds
Checkpoint/restore metrics: N/A (baseline execution; not run under DMTCP)
```

Definitions:

- **Total duration:** original launch through completion of the restored run;
- **Checkpoint time:** checkpoint request through visibility of all checkpoint
  images and the generated restart script;
- **Restore time:** restart-script launch until all expected DMTCP clients are
  confirmed as `RUNNING`;
- **Checkpoint total size:** all top-level `ckpt_*` files and associated
  `ckpt_*` directories;
- **Mean per rank:** checkpoint total size divided by the number of application
  MPI ranks;
- **Adaptive pre-restore cleanup:** the measured interval from the initial
  post-checkpoint shutdown request through disappearance of all captured
  PID/start-time identities, endpoint reusability verification, safe removal of
  matching stale filesystem Unix socket files, and the final verified-clear
  grace delay;
- **DMTCP checkpoint/restore workflow overhead:** sum of the checkpoint step,
  post-checkpoint stabilization, complete adaptive pre-restore cleanup, and
  restore step. The execution summary prints these components separately so
  this value is not confused with checkpoint time plus restore time alone;
- **Total DMTCP-related overhead:** checkpoint/restart total duration minus the
  mean of successful matching baseline runs. A positive value means that the
  complete DMTCP execution was slower than the baseline; a negative value means
  that it was faster;
- **Residual DMTCP runtime difference:** total DMTCP-related overhead minus the
  explicitly measured checkpoint/restore workflow overhead. This is a signed
  difference, not a value clamped to zero:
  - a positive value means that execution outside the checkpoint/restore
    workflow was slower than the baseline;
  - a negative value means that execution outside the checkpoint/restore
    workflow was faster than the baseline;
  - a value near zero means that no measurable difference was observed.

Important metric files:

```text
total_seconds.txt
checkpoint_seconds.txt
post_checkpoint_stabilization_seconds.txt
pre_restore_cleanup_seconds.txt
original_shutdown_seconds.txt
pre_restore_endpoint_verification_seconds.txt
pre_restore_final_grace_seconds.txt
socket_cleanup_sleep_seconds.txt
dmtcp_restore_seconds.txt
checkpoint_restore_workflow_overhead_seconds.txt
total_dmtcp_related_overhead_seconds.txt
total_dmtcp_related_overhead_percent.txt
residual_dmtcp_runtime_difference_seconds.txt
checkpoint_size_gb.txt
checkpoint_mean_per_rank_gb.txt
baseline_reference_seconds.txt
execution_summary.txt
```

The following files are retained as backward-compatible aliases or components
for existing analysis scripts and result directories:

```text
socket_cleanup_sleep_seconds.txt
checkpoint_restore_procedure_overhead_seconds.txt
residual_dmtcp_runtime_overhead_seconds.txt
additional_overhead_seconds.txt
additional_overhead_percent.txt
```

`socket_cleanup_sleep_seconds.txt` no longer represents a blind sleep. It is
the backward-compatible endpoint-verification plus final-grace component; when
added to `original_shutdown_seconds.txt`, it equals
`pre_restore_cleanup_seconds.txt`. New analysis should use the latter directly.

A direct checkpoint/restart run without a matching successful baseline still
records the DMTCP checkpoint/restore workflow overhead. The total DMTCP-related
overhead and residual DMTCP runtime difference are recorded as `N/A` because
they require a baseline reference.

Baseline result directories retain zero-valued compatibility files for older
analysis tools, but `execution_summary.txt`, `per_run_results.csv`, and
`aggregate_results.csv` expose DMTCP-specific baseline metrics as `N/A`, since
the baseline application is not launched under DMTCP.

### Summaries

The summarizer reads successful BT and CG runs, including baseline,
percentage-target, and direct-delay directories. It uses the new metric names
when available and falls back to the compatibility aliases for older result
directories.

With the default repository-local results path:

```bash
python3 scripts/summarize_results.py
```

This reads:

```text
<repository-root>/output/results/
```

With a custom results path:

```bash
python3 scripts/summarize_results.py \
  --results-root /scratch/npb-dmtcp-output/results
```

By default, the following files are written inside the selected results root:

```text
per_run_results.csv
aggregate_results.csv
```

A separate CSV destination may be selected without changing the input results
path:

```bash
python3 scripts/summarize_results.py \
  --results-root /scratch/npb-dmtcp-output/results \
  --output-dir /scratch/npb-dmtcp-summaries
```

`per_run_results.csv` contains one row per successful repetition, including the
adaptive cleanup duration, workflow overhead, total DMTCP-related overhead,
signed residual runtime difference, and explicit faster/slower interpretation
fields.
`aggregate_results.csv` groups matching repetitions and reports their means and
sample standard deviations. A group containing only one successful repetition
has a standard deviation of `0`.

### Checkpoint retention

Keep checkpoint files:

```bash
CHECKPOINT_CLEANUP_MODE=keep-checkpoints ./scripts/run_all.sh
```

Delete them after their sizes are measured:

```bash
CHECKPOINT_CLEANUP_MODE=delete-checkpoints ./scripts/run_all.sh
```

### Existing run directories

```bash
EXISTING_RUN_POLICY=replace ./scripts/run_all.sh  # default
EXISTING_RUN_POLICY=skip ./scripts/run_all.sh
EXISTING_RUN_POLICY=error ./scripts/run_all.sh
```

### Emergency cleanup

```bash
./scripts/kill_dmtcp_processes.sh
```

This terminates matching DMTCP, Hydra, MPI, BT, and CG processes owned by the
current user. Do not run it while another desired experiment is active.
