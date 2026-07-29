#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0

"""Static contract tests for the current repository workflow."""

from __future__ import annotations

from pathlib import Path
import hashlib
import re

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = REPO_ROOT / "scripts"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_repository_contract() -> None:
    installer = (SCRIPTS / "install_dmtcp_mpich_env.sh").read_text(encoding="utf-8")
    config = (SCRIPTS / "experiment_config.sh").read_text(encoding="utf-8")
    run_all = (SCRIPTS / "run_all.sh").read_text(encoding="utf-8")
    run_one = (SCRIPTS / "run_one.sh").read_text(encoding="utf-8")
    summarizer = (SCRIPTS / "summarize_results.py").read_text(encoding="utf-8")
    cleanup = (SCRIPTS / "adaptive_pre_restore_cleanup.py").read_text(encoding="utf-8")
    reservation = (SCRIPTS / "restore_port_reservation.py").read_text(encoding="utf-8")
    receive_window = (SCRIPTS / "restore_tcp_receive_window.py").read_text(encoding="utf-8")
    readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
    patch_dir = (
        REPO_ROOT
        / "patches"
        / "dmtcp-6896e12276a9fe449edb0cf206203ce01b19efe6"
    )
    backlog_patch_path = patch_dir / "connectionrewirer-backlog-1024.exact.patch"
    duplex_patch_path = patch_dir / "kernelbufferdrainer-duplex-refill.patch"
    old_duplex_override = patch_dir / "kernelbufferdrainer.cpp"

    require(backlog_patch_path.is_file(), "restore-backlog patch asset is missing")
    require(duplex_patch_path.is_file(), "duplex-refill patch asset is missing")
    require(not old_duplex_override.exists(), "obsolete full-source override remains")

    backlog_patch = backlog_patch_path.read_text(encoding="utf-8")
    duplex_patch = duplex_patch_path.read_text(encoding="utf-8")
    backlog_patch_sha256 = hashlib.sha256(backlog_patch_path.read_bytes()).hexdigest()
    duplex_patch_sha256 = hashlib.sha256(duplex_patch_path.read_bytes()).hexdigest()
    require(
        backlog_patch_sha256 == "72bc6bc3d338a78c9e1ebe89692f12c544e92ad2862be58b8aca942702a981a1",
        f"unexpected restore-backlog patch checksum: {backlog_patch_sha256}",
    )
    require(
        duplex_patch_sha256 == "93a2edf137e6214410b436ecbed1ae0d6cf3056e2bb6325910d52e50e3df28a2",
        f"unexpected duplex-refill patch checksum: {duplex_patch_sha256}",
    )

    require('BUILD_JOBS="${BUILD_JOBS:-8}"' in installer, "BUILD_JOBS default is missing")
    require('make -j"${BUILD_JOBS}"' in installer, "installer does not use BUILD_JOBS")
    require('make -j"$(nproc)"' not in installer, "unbounded nproc build remains")

    require(
        "FROM=jalib::JServerSocket restoreSocket(sockAddr, 0);" in backlog_patch,
        "backlog patch FROM directive missing for the primary IPv4 listener",
    )
    require(
        "TO=jalib::JServerSocket restoreSocket(sockAddr, 0, 1024);" in backlog_patch,
        "backlog patch TO directive missing for the primary IPv4 listener",
    )
    for fd_name in ("ip6fd", "udsfd", "udsseqfd"):
        require(
            f"FROM=_real_listen({fd_name}, 32)" in backlog_patch,
            f"backlog patch FROM directive missing for {fd_name}",
        )
        require(
            f"TO=_real_listen({fd_name}, 1024)" in backlog_patch,
            f"backlog patch TO directive missing for {fd_name}",
        )
    require(
        'WORKING_DMTCP_RESTORE_LISTEN_BACKLOG="1024"' in installer,
        "installer backlog constant is not 1024",
    )
    require(
        'WORKING_DMTCP_RESTORE_LISTEN_BACKLOG="${WORKING_DMTCP_RESTORE_LISTEN_BACKLOG:-1024}"'
        in config,
        "configuration backlog default is missing",
    )
    require("DMTCP restore-listener backlog" in readme, "README backlog documentation missing")
    require(
        'DMTCP_RESTORE_LISTENER_PATHS="4"' in installer,
        "environment helper does not report four patched listener paths",
    )

    require(
        'WORKING_DMTCP_BACKLOG_PATCH_SHA256=' in installer,
        "installer backlog-patch checksum is missing",
    )
    require(
        'WORKING_DMTCP_DUPLEX_PATCH_SHA256=' in installer,
        "installer duplex-patch checksum is missing",
    )
    require(
        'DMTCP_BACKLOG_PATCH_FILE=' in installer,
        "installer does not locate the backlog patch asset",
    )
    require(
        'DMTCP_DUPLEX_REFILL_PATCH_FILE=' in installer,
        "installer does not locate the duplex patch asset",
    )
    require(
        'patch --batch --forward --fuzz=0 -p1' in installer,
        "installer does not strictly apply the unified duplex patch",
    )
    require(
        'stream-refill payload send failed' in duplex_patch,
        "duplex-refill patch lacks its state-machine marker",
    )
    require(
        'stream-refill receive buffer is too small' in duplex_patch,
        "duplex-refill patch lacks receive-capacity verification",
    )
    require('SO_RCVBUFFORCE' in duplex_patch, "duplex-refill patch lacks privileged receive-buffer fallback")
    require(
        'failed to restore stream-refill receive buffer size' in duplex_patch,
        "duplex-refill patch does not restore the original receive-buffer setting",
    )
    require('+#include <poll.h>' in duplex_patch, "duplex-refill patch lacks poll support")
    require(
        'replacements = (' not in installer,
        "old embedded backlog replacement table remains in installer",
    )
    require(
        'WORKING_DMTCP_DUPLEX_PATCH_SHA256=' in config,
        "configuration duplex-refill patch checksum is missing",
    )
    require(
        "DMTCP_REFILL_RECEIVE_CAPACITY_PATCH_ACTIVE=1" in config,
        "runtime receive-capacity plugin verification is missing",
    )
    require(
        "failed to restore stream-refill receive buffer size" in config,
        "runtime verification lacks a release-stable receive-capacity marker",
    )
    require(
        "temporarily expanded stream-refill receive buffer' \"${dmtcp_ipc_plugin}\"" not in config,
        "runtime verification still depends on a JTRACE-only marker",
    )
    require(
        "JTRACE text may be omitted by optimized builds" in installer,
        "installer does not document release-stable plugin verification",
    )
    readme_normalized = " ".join(readme.split())
    require(
        "receive-capacity-aware nonblocking duplex state machine"
        in readme_normalized,
        "README receive-capacity duplex-refill documentation missing",
    )

    require(
        'RESTORE_MAX_ATTEMPTS="${RESTORE_MAX_ATTEMPTS:-3}"' in config,
        "restore-attempt default is missing",
    )
    require(
        'RESTORE_RETRY_FINAL_GRACE_SECONDS="${RESTORE_RETRY_FINAL_GRACE_SECONDS:-10}"'
        in config,
        "restore retry grace default is missing",
    )
    require("cleanup_failed_restore_attempt" in run_one, "failed-attempt cleanup is missing")
    require(
        'local apply_retry_grace="${3:-true}"' in run_one,
        "failed-attempt cleanup cannot distinguish a real retry from final cleanup",
    )
    require(
        'APPLY_RETRY_GRACE="false"' in run_one,
        "final failed restore attempt still applies the retry-only grace",
    )
    require(
        "skipped after the final failed attempt" in readme,
        "README does not document final-attempt grace behavior",
    )
    require("restore_attempts_summary.tsv" in run_one, "restore-attempt summary is missing")
    require("successful_restore_attempt_seconds.txt" in run_one, "successful-attempt metric is missing")
    require("restore_attempt_count" in summarizer, "summarizer does not expose restore-attempt counts")
    require("restore_retry_count" in summarizer, "summarizer does not expose restore-retry counts")
    require("Automatic restore retries" in readme, "README restore-retry documentation missing")
    require(
        'RESTORE_RESERVE_ORIGINAL_TCP_PORTS="${RESTORE_RESERVE_ORIGINAL_TCP_PORTS:-true}"'
        in config,
        "restore-port reservation default is missing",
    )
    require("reserve_restore_ports" in run_one, "restore-port reservation setup is missing")
    require("release_restore_ports" in run_one, "restore-port reservation release is missing")
    require("flock -w" in run_one, "restore-port reservation is not serialized")
    require("ip_local_reserved_ports" in reservation, "reservation helper targets no sysctl")
    require(
        "captured_ipv4_tcp_listener_ports" in reservation,
        "reservation helper does not extract captured listeners",
    )
    require(
        "Restore-port collision protection" in readme,
        "README restore-port protection documentation missing",
    )

    require(
        'RESTORE_TUNE_TCP_RECEIVE_WINDOW="${RESTORE_TUNE_TCP_RECEIVE_WINDOW:-true}"'
        in config,
        "restore TCP receive-window tuning default is missing",
    )
    require(
        'RESTORE_NET_CORE_RMEM_MAX="${RESTORE_NET_CORE_RMEM_MAX:-16777216}"'
        in config,
        "restore rmem_max floor is missing",
    )
    require(
        'RESTORE_NET_IPV4_TCP_RMEM="${RESTORE_NET_IPV4_TCP_RMEM:-4096 4194304 16777216}"'
        in config,
        "restore tcp_rmem floor is missing",
    )
    require(
        "apply_restore_tcp_receive_window" in run_one,
        "restore TCP receive-window setup is missing",
    )
    require(
        "release_restore_tcp_receive_window" in run_one,
        "restore TCP receive-window release is missing",
    )
    restore_phase = run_one.index('RESTORE_START_NS="$(now_ns)"')
    require(
        run_one.index("apply_restore_tcp_receive_window", restore_phase)
        < run_one.index("reserve_restore_ports", restore_phase),
        "TCP receive-window tuning is not applied before restore port reservation",
    )
    require(
        "net.core.rmem_max" in receive_window and "net.ipv4.tcp_rmem" in receive_window,
        "receive-window helper does not manage both required sysctls",
    )
    require(
        "Never lower host settings" in receive_window,
        "receive-window helper does not preserve higher host settings",
    )
    require(
        "restore_original_values" in receive_window,
        "receive-window helper lacks transactional rollback/restoration",
    )
    require(
        "Restore-scoped TCP receive-window tuning" in readme,
        "README receive-window transaction documentation missing",
    )

    final_wait = run_one.index('wait "${RESTORED_PID}"', run_one.index("monitor_background_process"))
    final_refresh = run_one.index(
        'copy_restore_attempt_to_canonical_logs "${SUCCESSFUL_ATTEMPT_DIR}"',
        final_wait,
    )
    verification = run_one.index(
        "verify_npb_output stdout_before_ckpt.log stdout_after_restore.log",
        final_refresh,
    )
    require(final_wait < final_refresh < verification, "final restored logs are not refreshed before NPB verification")

    require('EXISTING_RUN_POLICY="${EXISTING_RUN_POLICY:-resume}"' in config, "resume is not the default")
    require('"${RUN_DIR}/SUCCESS.marker"' in run_one, "run_one does not inspect SUCCESS.marker")
    require('mv -f -- "${temporary_marker}" SUCCESS.marker' in run_one, "atomic success marker creation missing")
    require('run_dir / "SUCCESS.marker"' in run_all, "run_all baseline validation does not use marker")
    require('run_dir / "SUCCESS.marker"' in summarizer, "summarizer does not use marker")

    cleanup_call = '"${SCRIPT_DIR}/kill_dmtcp_processes.sh" > pre_run_cleanup.log 2>&1'
    require(cleanup_call in run_one, "pre-run process cleanup call is missing")
    cleanup_position = run_one.index(cleanup_call)
    require(cleanup_position < run_one.index('mpirun -np "${NP}"'), "cleanup is not before baseline launch")
    require(cleanup_position < run_one.index('dmtcp_coordinator --coord-port'), "cleanup is not before CR launch")

    forbidden_artifacts = (
        "additional_overhead_seconds.txt",
        "additional_overhead_percent.txt",
        "checkpoint_overhead_seconds.txt",
        "checkpoint_restore_procedure_overhead_seconds.txt",
        "residual_dmtcp_runtime_overhead_seconds.txt",
        "socket_cleanup_sleep_seconds.txt",
        "total_wall_seconds.txt",
    )
    production_text = "\n".join(
        (run_one, summarizer, cleanup, reservation, receive_window, readme)
    )
    for artifact in forbidden_artifacts:
        require(artifact not in production_text, f"obsolete artifact remains: {artifact}")

    require(
        re.search(r"(?<!dmtcp_)restore_seconds\.txt", production_text) is None,
        "obsolete restore_seconds.txt alias remains",
    )
    require("baseline_t*_rep" not in run_one, "old baseline directory lookup remains")
    require("legacy_baseline_target" not in summarizer, "old baseline name parser remains")
    require("replace|skip|error" not in run_one + run_all, "old skip policy remains")
    require(not (REPO_ROOT / ".idea").exists(), ".idea directory is present")



if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__]))
