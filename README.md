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
5. Kill the original DMTCP computation and let the coordinator exit;
6. Wait for operating-system socket cleanup;
7. Execute the generated restart script without extra coordinator arguments;
8. Wait until every DMTCP client reports `WorkerState::RUNNING`;
9. Wait for NPB completion and verify `Verification = SUCCESSFUL`.

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
chmod +x scripts/*.sh scripts/summarize_results.py
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

All generated repository artifacts can be redirected with **one variable**:

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

To use a custom output path for one command:

```bash
OUTPUT_ROOT=/scratch/npb-dmtcp-output \
./scripts/run_all.sh
```

To use the same custom output path for multiple commands in the current shell:

```bash
export OUTPUT_ROOT=/scratch/npb-dmtcp-output
```

Then run the build and experiments normally:

```bash
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

Then verify the environment and binary linkage with the same path settings:

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

Defaults are defined in `scripts/experiment_config.sh`:

```bash
BENCHMARKS_TEXT="bt cg"
MPI_RANKS_TEXT="4"
BASELINE_REPETITIONS_TEXT="1 2 3"
CR_REPETITIONS_TEXT="1 2 3"
CHECKPOINT_PERCENTAGES_TEXT="25 50 75"
NPB_CLASS="D"
SOCKET_CLEANUP_SLEEP_SECONDS="10"
DMTCP_EXPERIMENT_SIGNAL="30"
```

Small validation:

```bash
OUTPUT_ROOT=/scratch/npb-dmtcp-output \
BENCHMARKS_TEXT="bt" \
MPI_RANKS_TEXT="25" \
BASELINE_REPETITIONS_TEXT="1" \
CR_REPETITIONS_TEXT="1" \
CHECKPOINT_PERCENTAGES_TEXT="10" \
CHECKPOINT_CLEANUP_MODE="keep-checkpoints" \
./scripts/run_all.sh
```

Full configured matrix:

```bash
./scripts/run_all.sh
```

The suite runs baseline repetitions first, calculates their mean, and converts
each checkpoint percentage into an absolute delay.

### Execution messages

A checkpoint/restart execution reports each phase explicitly:

```text
[coordinator] Starting a fresh DMTCP coordinator...
[run] Launching BT.D with 25 MPI ranks under DMTCP.
[checkpoint] Detected 27 DMTCP clients; creating checkpoint images now.
[checkpoint] Checkpoint recorded successfully at ...
[checkpoint] Checkpoint storage: ... GB total | ... GB mean per rank.
[shutdown] Killing the original DMTCP clients...
[shutdown] Original computation and coordinator terminated.
[cleanup] Waiting 10 seconds for operating-system socket cleanup.
[restore] Restoring checkpoints using script: ...
[restore] Progress: 27/27 clients RUNNING.
[restore] Restore complete; step took ... seconds.
[run] Restored application is still running...
[complete] NPB verification was SUCCESSFUL.
```

### Measurements

Every successful run contains `execution_summary.txt`:

```text
Total duration: X seconds
Size of checkpoints: Y1 GB total | Y2 GB mean per application rank
Time required for the checkpoint step: X seconds
Time required for the restore step: X seconds
Additional overhead: X seconds (... compared with baseline mean ...)
```

Definitions:

- **Total duration:** original launch through completion of the restored run;
- **Checkpoint time:** checkpoint request through visibility of all images and
  the restart script;
- **Restore time:** restart-script launch until all expected DMTCP clients are
  confirmed as `RUNNING`;
- **Checkpoint total size:** all top-level `ckpt_*` files and associated
  `ckpt_*` directories;
- **Mean per rank:** checkpoint total size divided by application MPI ranks;
- **Additional overhead:** checkpoint/restart total duration minus the mean of
  successful matching baseline runs.

Important metric files:

```text
total_seconds.txt
checkpoint_seconds.txt
dmtcp_restore_seconds.txt
checkpoint_size_gb.txt
checkpoint_mean_per_rank_gb.txt
baseline_reference_seconds.txt
additional_overhead_seconds.txt
additional_overhead_percent.txt
execution_summary.txt
```

A direct checkpoint/restart run without a matching successful baseline records
the additional overhead as `N/A`.

### Summaries

With the default output path:

```bash
python3 scripts/summarize_results.py
```

With a custom results path:

```bash
python3 scripts/summarize_results.py \
  --results-root /scratch/npb-dmtcp-output/results
```

Generated CSV files:

```text
per_run_results.csv
aggregate_results.csv
```

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
