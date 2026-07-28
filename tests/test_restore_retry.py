#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0

"""Integration test for bounded same-checkpoint restore retries."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap


REPO_ROOT = Path(__file__).resolve().parent.parent
RUN_ONE = REPO_ROOT / "scripts" / "run_one.sh"


def make_executable(path: Path, text: str) -> None:
    path.write_text(textwrap.dedent(text).lstrip(), encoding="utf-8")
    path.chmod(0o755)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="npb-restore-retry-") as temp_text:
        temp = Path(temp_text)
        fake_bin = temp / "fake-bin"
        state = temp / "state"
        output = temp / "output"
        binaries = output / "binaries"
        results = output / "results"
        fake_bin.mkdir()
        state.mkdir()
        binaries.mkdir(parents=True)
        results.mkdir(parents=True)

        benchmark = binaries / "cg.D.x"
        make_executable(
            benchmark,
            """
            #!/usr/bin/env bash
            trap 'exit 0' TERM INT
            while true; do sleep 1; done
            """,
        )

        make_executable(
            fake_bin / "mpirun",
            """
            #!/usr/bin/env bash
            if [ "${1:-}" = "-np" ]; then shift 2; fi
            exec "$@"
            """,
        )

        make_executable(
            fake_bin / "dmtcp_launch",
            """
            #!/usr/bin/env bash
            state=${FAKE_DMTCP_STATE:?}
            if [ "${1:-}" = "--coord-port" ]; then shift 2; fi
            echo $$ > "$state/app.pid"
            echo original_running > "$state/mode"
            exec "$@"
            """,
        )

        make_executable(
            fake_bin / "dmtcp_coordinator",
            """
            #!/usr/bin/env bash
            state=${FAKE_DMTCP_STATE:?}
            echo $$ > "$state/coordinator.pid"
            trap 'exit 0' TERM INT
            while true; do sleep 1; done
            """,
        )

        make_executable(
            fake_bin / "dmtcp_command",
            r"""
            #!/usr/bin/env bash
            set -u
            state=${FAKE_DMTCP_STATE:?}
            action=""
            for arg in "$@"; do
              case "$arg" in
                --list|--checkpoint|--kill) action="$arg" ;;
              esac
            done

            emit_clients() {
              local worker_state=$1
              local barrier=$2
              local i
              echo "Coordinator:"
              echo "  Host: localhost"
              echo "  Port: 29977"
              echo "Client List:"
              echo "#, PROG[virtPID:realPID]@HOST, DMTCP-UNIQUEPID, STATE, BARRIER"
              for i in 1 2 3 4; do
                echo "$i, fake[$((40000+i)):$$]@localhost, fake-$i, WorkerState::$worker_state, $barrier"
              done
            }

            case "$action" in
              --list)
                mode=$(cat "$state/mode" 2>/dev/null || echo idle)
                case "$mode" in
                  original_running|running)
                    emit_clients RUNNING ""
                    ;;
                  restarting)
                    emit_clients RESTARTING Socket::Restart_Ns_Register_Data
                    ;;
                esac
                exit 0
                ;;
              --checkpoint)
                checkpoint_count=0
                [ ! -f "$state/checkpoint_count" ] || checkpoint_count=$(cat "$state/checkpoint_count")
                echo $((checkpoint_count + 1)) > "$state/checkpoint_count"
                for i in 1 2 3 4; do
                  : > "ckpt_fake_${i}.dmtcp"
                done
                cat > dmtcp_restart_script_fake.sh <<'EOF'
            #!/usr/bin/env bash
            set -u
            state=${FAKE_DMTCP_STATE:?}
            count=0
            [ ! -f "$state/attempt_count" ] || count=$(cat "$state/attempt_count")
            count=$((count + 1))
            echo "$count" > "$state/attempt_count"
            echo $$ > "$state/restored.pid"
            trap 'exit 0' TERM INT
            if [ "$count" -eq 1 ]; then
              echo restarting > "$state/mode"
              while true; do sleep 1; done
            fi
            echo running > "$state/mode"
            # DMTCP reaches RUNNING before the restored application emits its
            # final benchmark output. This reproduces the stale canonical-log
            # bug that occurred with CG.D after a successful restore.
            sleep 2
            echo 'Verification = SUCCESSFUL'
            EOF
                chmod +x dmtcp_restart_script_fake.sh
                exit 0
                ;;
              --kill)
                for name in app.pid coordinator.pid restored.pid; do
                  if [ -f "$state/$name" ]; then
                    pid=$(cat "$state/$name")
                    kill -TERM "$pid" 2>/dev/null || true
                  fi
                done
                echo idle > "$state/mode"
                exit 0
                ;;
              *)
                exit 0
                ;;
            esac
            """,
        )

        env_file = temp / "fake-env.sh"
        env_file.write_text(
            f'export PATH="{fake_bin}:$PATH"\n'
            'export DMTCP_SIGCKPT="30"\n',
            encoding="utf-8",
        )

        fake_rmem_max = temp / "net_core_rmem_max"
        fake_tcp_rmem = temp / "net_ipv4_tcp_rmem"
        fake_rmem_max.write_text("212992\n", encoding="utf-8")
        fake_tcp_rmem.write_text("4096 131072 6291456\n", encoding="utf-8")

        env = os.environ.copy()
        env.update(
            {
                "ENV_FILE": str(env_file),
                "OUTPUT_ROOT": str(output),
                "BINARY_ROOT": str(binaries),
                "RESULTS_ROOT": str(results),
                "REQUIRE_WORKING_STACK": "false",
                "FAKE_DMTCP_STATE": str(state),
                "EXISTING_RUN_POLICY": "replace",
                "DMTCP_RESTORE_TIMEOUT_SECONDS": "1",
                "RESTORE_MAX_ATTEMPTS": "2",
                "RESTORE_RETRY_FINAL_GRACE_SECONDS": "0",
                "RESTORE_BIND_FAILURE_ABORT_SECONDS": "1",
                "RESTORE_RESERVE_ORIGINAL_TCP_PORTS": "false",
                "RESTORE_TUNE_TCP_RECEIVE_WINDOW": "true",
                "RESTORE_TCP_RECEIVE_WINDOW_LOCK_FILE": str(temp / "receive-window.lock"),
                "RESTORE_TCP_RECEIVE_WINDOW_LOCK_TIMEOUT_SECONDS": "5",
                "RESTORE_NET_CORE_RMEM_MAX": "16777216",
                "RESTORE_NET_IPV4_TCP_RMEM": "4096 4194304 16777216",
                "RESTORE_NET_CORE_RMEM_MAX_PATH": str(fake_rmem_max),
                "RESTORE_NET_IPV4_TCP_RMEM_PATH": str(fake_tcp_rmem),
                "PRE_RESTORE_CLEANUP_TIMEOUT_SECONDS": "10",
                "PRE_RESTORE_CLEANUP_POLL_SECONDS": "0.05",
                "PRE_RESTORE_FORCE_KILL_AFTER_SECONDS": "0.2",
                "PRE_RESTORE_FORCE_KILL_GRACE_SECONDS": "0.2",
                "PRE_RESTORE_FINAL_GRACE_SECONDS": "0",
                "PRE_RESTORE_CLEANUP_REPORT_INTERVAL_SECONDS": "1",
                "POST_CHECKPOINT_STABILIZATION_SECONDS": "0",
                "COORDINATOR_START_TIMEOUT_SECONDS": "5",
                "CHECKPOINT_FILE_TIMEOUT_SECONDS": "5",
                "PROGRESS_INTERVAL_SECONDS": "1",
                "RESTORE_PROGRESS_INTERVAL_SECONDS": "1",
                "DMTCP_COORD_PORT": "29977",
            }
        )

        stdout_path = temp / "run.stdout.log"
        stderr_path = temp / "run.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout_file, \
             stderr_path.open("w", encoding="utf-8") as stderr_file:
            completed = subprocess.run(
                [
                    str(RUN_ONE),
                    "cg",
                    "2",
                    "cr",
                    "delay",
                    "0.1",
                    "1",
                    "keep-checkpoints",
                ],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=stdout_file,
                stderr=stderr_file,
                check=False,
                timeout=45,
            )
        stdout_text = stdout_path.read_text(encoding="utf-8")
        stderr_text = stderr_path.read_text(encoding="utf-8")
        if completed.returncode != 0:
            raise AssertionError(
                f"retry integration run failed with {completed.returncode}\n"
                f"stdout:\n{stdout_text}\nstderr:\n{stderr_text}"
            )

        run_dir = results / "cgD_np2_cr_t0p1_rep1"
        checks = {
            "SUCCESS.marker": run_dir / "SUCCESS.marker",
            "attempt 1 failure": run_dir / "restore_attempts/attempt_01/status.txt",
            "attempt 2 success": run_dir / "restore_attempts/attempt_02/status.txt",
            "attempt summary": run_dir / "restore_attempts_summary.tsv",
            "attempt count": run_dir / "restore_attempt_count.txt",
            "retry count": run_dir / "restore_retry_count.txt",
            "successful attempt metric": run_dir / "successful_restore_attempt_seconds.txt",
        }
        for label, path in checks.items():
            if not path.is_file():
                raise AssertionError(f"missing {label}: {path}")

        if fake_rmem_max.read_text(encoding="utf-8").strip() != "212992":
            raise AssertionError("retry integration did not restore net.core.rmem_max")
        if fake_tcp_rmem.read_text(encoding="utf-8").strip() != "4096 131072 6291456":
            raise AssertionError("retry integration did not restore net.ipv4.tcp_rmem")
        if (run_dir / "restore_tcp_receive_window_status.txt").read_text(encoding="utf-8").strip() != "RELEASED":
            raise AssertionError("receive-window transaction was not released")

        if checks["attempt 1 failure"].read_text().strip() != "FAILED":
            raise AssertionError("first restore attempt was not recorded as FAILED")
        if checks["attempt 2 success"].read_text().strip() != "SUCCESS":
            raise AssertionError("second restore attempt was not recorded as SUCCESS")
        if checks["attempt count"].read_text().strip() != "2":
            raise AssertionError("restore_attempt_count.txt is not 2")
        if checks["retry count"].read_text().strip() != "1":
            raise AssertionError("restore_retry_count.txt is not 1")
        if (state / "checkpoint_count").read_text().strip() != "1":
            raise AssertionError("checkpoint was recreated instead of reused")
        if (state / "attempt_count").read_text().strip() != "2":
            raise AssertionError("generated restart script was not launched exactly twice")
        if "Restore complete on attempt 2/2" not in stdout_text:
            raise AssertionError("successful retry was not reported")
        if not (run_dir / "restore_attempts/attempt_01/retry_cleanup").is_dir():
            raise AssertionError("failed-attempt retry cleanup artifacts are missing")

        attempt_stdout = run_dir / "restore_attempts/attempt_02/stdout.log"
        canonical_stdout = run_dir / "stdout_after_restore.log"
        attempt_text = attempt_stdout.read_text(encoding="utf-8")
        canonical_text = canonical_stdout.read_text(encoding="utf-8")
        if "Verification = SUCCESSFUL" not in canonical_text:
            raise AssertionError(
                "canonical restored stdout was not refreshed after the application exited"
            )
        if canonical_text != attempt_text:
            raise AssertionError(
                "canonical restored stdout does not match the complete successful-attempt log"
            )

    print(
        "[OK] first restore attempt stalls, the same checkpoint succeeds on "
        "attempt two, and final canonical logs are refreshed after application exit"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
