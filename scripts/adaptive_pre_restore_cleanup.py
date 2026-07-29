#!/usr/bin/env python3

# Copyright 2026 Alan Lira Nunes
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the repository root for details.

"""Capture and safely release process/socket resources before DMTCP restore.

The capture phase records process identities as (PID, /proc start time) pairs so
PID reuse cannot cause a later signal to target an unrelated process. It also
records TCP, UDP, and Unix-domain sockets referenced by those exact processes.

The cleanup phase waits for the captured processes to disappear, escalates TERM
and KILL only for still-matching captured identities, verifies that captured
endpoints can be rebound, removes only matching stale filesystem Unix socket
files owned by the invoking user, and refuses to kill unrelated endpoint owners.
"""

from __future__ import annotations

import argparse
import dataclasses
import errno
import json
import os
from pathlib import Path
import signal
import socket
import stat
import sys
import time
from typing import Dict, Iterable, List, Mapping, MutableMapping, Optional, Sequence, Set, Tuple


PROC_ROOT = Path("/proc")
NETWORK_TABLES = (
    ("tcp", socket.AF_INET, socket.SOCK_STREAM, PROC_ROOT / "net" / "tcp"),
    ("tcp6", socket.AF_INET6, socket.SOCK_STREAM, PROC_ROOT / "net" / "tcp6"),
    ("udp", socket.AF_INET, socket.SOCK_DGRAM, PROC_ROOT / "net" / "udp"),
    ("udp6", socket.AF_INET6, socket.SOCK_DGRAM, PROC_ROOT / "net" / "udp6"),
)


class CleanupError(RuntimeError):
    """Base class for expected cleanup failures."""


class UnrelatedEndpointOwner(CleanupError):
    """A captured endpoint is currently occupied by an unrelated process."""


class CleanupTimeout(CleanupError):
    """The complete adaptive cleanup exceeded its configured timeout."""


@dataclasses.dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    start_time_ticks: int
    ppid: int
    command: str

    @property
    def key(self) -> Tuple[int, int]:
        return (self.pid, self.start_time_ticks)


@dataclasses.dataclass(frozen=True)
class SocketEndpoint:
    inode: int
    protocol: str
    family: str
    sock_type: str
    local_address: Optional[str] = None
    local_port: Optional[int] = None
    remote_address: Optional[str] = None
    remote_port: Optional[int] = None
    state: Optional[str] = None
    unix_path: Optional[str] = None
    unix_abstract: bool = False
    filesystem_device: Optional[int] = None
    filesystem_inode: Optional[int] = None
    filesystem_uid: Optional[int] = None

    def signature(self) -> Tuple[object, ...]:
        if self.protocol == "unix":
            return ("unix", self.unix_abstract, self.unix_path)
        return (self.protocol, self.family, self.local_address, self.local_port)


@dataclasses.dataclass
class CleanupMeasurements:
    total_seconds: float
    process_shutdown_seconds: float
    endpoint_verification_seconds: float
    final_grace_seconds: float
    term_sent: bool
    kill_sent: bool
    stale_unix_socket_files_removed: List[str]


def monotonic() -> float:
    return time.monotonic()


def parse_nonnegative_float(value: str) -> float:
    parsed = float(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("value must be nonnegative")
    return parsed


def parse_positive_float(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be greater than zero")
    return parsed


def boot_id() -> str:
    try:
        return (PROC_ROOT / "sys" / "kernel" / "random" / "boot_id").read_text().strip()
    except OSError:
        return "unknown"


def process_stat(pid: int) -> Optional[Tuple[int, int, str]]:
    """Return (ppid, start_time_ticks, command) for PID, or None if gone."""
    try:
        raw = (PROC_ROOT / str(pid) / "stat").read_text(encoding="utf-8")
    except (FileNotFoundError, ProcessLookupError, PermissionError, OSError):
        return None

    right_paren = raw.rfind(")")
    if right_paren < 0:
        return None
    command = raw[raw.find("(") + 1 : right_paren]
    fields = raw[right_paren + 2 :].split()
    if len(fields) < 20:
        return None
    # fields[0] is state (field 3 in proc_pid_stat), fields[1] is ppid (4),
    # and fields[19] is starttime (22).
    try:
        return int(fields[1]), int(fields[19]), command
    except ValueError:
        return None



def process_state(pid: int) -> Optional[str]:
    try:
        raw = (PROC_ROOT / str(pid) / "stat").read_text(encoding="utf-8")
    except (FileNotFoundError, ProcessLookupError, PermissionError, OSError):
        return None
    right_paren = raw.rfind(")")
    if right_paren < 0:
        return None
    fields = raw[right_paren + 2 :].split()
    return fields[0] if fields else None


def process_cmdline(pid: int, fallback: str) -> str:
    try:
        raw = (PROC_ROOT / str(pid) / "cmdline").read_bytes()
    except OSError:
        return fallback
    text = raw.replace(b"\0", b" ").decode("utf-8", errors="replace").strip()
    return text or fallback


def process_identity(pid: int) -> Optional[ProcessIdentity]:
    details = process_stat(pid)
    if details is None:
        return None
    ppid, start_time_ticks, comm = details
    return ProcessIdentity(
        pid=pid,
        start_time_ticks=start_time_ticks,
        ppid=ppid,
        command=process_cmdline(pid, comm),
    )


def all_process_identities() -> Dict[int, ProcessIdentity]:
    result: Dict[int, ProcessIdentity] = {}
    try:
        entries = list(PROC_ROOT.iterdir())
    except OSError:
        return result
    for entry in entries:
        if not entry.name.isdigit():
            continue
        identity = process_identity(int(entry.name))
        if identity is not None:
            result[identity.pid] = identity
    return result


def capture_process_tree(root_pids: Sequence[int]) -> List[ProcessIdentity]:
    """Capture roots and descendants until the identity set stabilizes."""
    previous_keys: Optional[Set[Tuple[int, int]]] = None
    stable_rounds = 0
    captured: Dict[Tuple[int, int], ProcessIdentity] = {}

    for _ in range(30):
        snapshot = all_process_identities()
        children: Dict[int, List[int]] = {}
        for identity in snapshot.values():
            children.setdefault(identity.ppid, []).append(identity.pid)

        pending = list(dict.fromkeys(root_pids))
        seen_pids: Set[int] = set()
        current: Dict[Tuple[int, int], ProcessIdentity] = {}
        while pending:
            pid = pending.pop()
            if pid in seen_pids:
                continue
            seen_pids.add(pid)
            identity = snapshot.get(pid)
            if identity is None:
                continue
            current[identity.key] = identity
            pending.extend(children.get(pid, ()))

        if not current:
            raise CleanupError("none of the requested root processes exists")

        captured.update(current)
        keys = set(captured)
        if keys == previous_keys:
            stable_rounds += 1
            if stable_rounds >= 2:
                break
        else:
            stable_rounds = 0
            previous_keys = keys
        time.sleep(0.05)

    for root_pid in root_pids:
        if not any(identity.pid == root_pid for identity in captured.values()):
            raise CleanupError(f"required root PID {root_pid} disappeared during capture")

    return sorted(captured.values(), key=lambda item: (item.pid, item.start_time_ticks))


def socket_inodes_for_processes(processes: Sequence[ProcessIdentity]) -> Dict[int, Set[Tuple[int, int]]]:
    owners: Dict[int, Set[Tuple[int, int]]] = {}
    for identity in processes:
        if not identity_matches(identity):
            continue
        fd_dir = PROC_ROOT / str(identity.pid) / "fd"
        try:
            entries = list(fd_dir.iterdir())
        except OSError:
            continue
        for entry in entries:
            try:
                target = os.readlink(entry)
            except OSError:
                continue
            if not (target.startswith("socket:[") and target.endswith("]")):
                continue
            try:
                inode = int(target[8:-1])
            except ValueError:
                continue
            owners.setdefault(inode, set()).add(identity.key)
    return owners


def decode_proc_address(encoded: str, family: int) -> Tuple[str, int]:
    address_hex, port_hex = encoded.split(":", 1)
    raw = bytes.fromhex(address_hex)
    if family == socket.AF_INET:
        packed = raw[::-1]
    else:
        packed = b"".join(raw[index : index + 4][::-1] for index in range(0, 16, 4))
    return socket.inet_ntop(family, packed), int(port_hex, 16)


def parse_inet_table(
    protocol: str, family: int, sock_type: int, path: Path
) -> Dict[int, SocketEndpoint]:
    endpoints: Dict[int, SocketEndpoint] = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()[1:]
    except OSError:
        return endpoints
    for line in lines:
        fields = line.split()
        if len(fields) < 10:
            continue
        try:
            local_address, local_port = decode_proc_address(fields[1], family)
            remote_address, remote_port = decode_proc_address(fields[2], family)
            inode = int(fields[9])
        except (ValueError, OSError):
            continue
        endpoints[inode] = SocketEndpoint(
            inode=inode,
            protocol=protocol.rstrip("6"),
            family="ipv4" if family == socket.AF_INET else "ipv6",
            sock_type="stream" if sock_type == socket.SOCK_STREAM else "datagram",
            local_address=local_address,
            local_port=local_port,
            remote_address=remote_address,
            remote_port=remote_port,
            state=fields[3],
        )
    return endpoints


def parse_unix_table(path: Path) -> Dict[int, SocketEndpoint]:
    endpoints: Dict[int, SocketEndpoint] = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()[1:]
    except OSError:
        return endpoints
    for line in lines:
        fields = line.split(maxsplit=7)
        if len(fields) < 7:
            continue
        try:
            inode = int(fields[6])
        except ValueError:
            continue
        unix_path = fields[7] if len(fields) >= 8 else None
        abstract = bool(unix_path and unix_path.startswith("@"))
        filesystem_device: Optional[int] = None
        filesystem_inode: Optional[int] = None
        filesystem_uid: Optional[int] = None
        if unix_path and not abstract:
            try:
                info = os.lstat(unix_path)
            except OSError:
                pass
            else:
                filesystem_device = info.st_dev
                filesystem_inode = info.st_ino
                filesystem_uid = info.st_uid
        endpoints[inode] = SocketEndpoint(
            inode=inode,
            protocol="unix",
            family="unix",
            sock_type=fields[4],
            state=fields[5],
            unix_path=unix_path,
            unix_abstract=abstract,
            filesystem_device=filesystem_device,
            filesystem_inode=filesystem_inode,
            filesystem_uid=filesystem_uid,
        )
    return endpoints


def current_socket_table() -> Dict[int, SocketEndpoint]:
    result: Dict[int, SocketEndpoint] = {}
    for protocol, family, sock_type, path in NETWORK_TABLES:
        result.update(parse_inet_table(protocol, family, sock_type, path))
    result.update(parse_unix_table(PROC_ROOT / "net" / "unix"))
    return result


def capture_socket_endpoints(processes: Sequence[ProcessIdentity]) -> Tuple[List[SocketEndpoint], Dict[int, Set[Tuple[int, int]]]]:
    owners = socket_inodes_for_processes(processes)
    table = current_socket_table()
    endpoints = [table[inode] for inode in sorted(owners) if inode in table]
    return endpoints, owners


def identity_matches(identity: ProcessIdentity) -> bool:
    current = process_stat(identity.pid)
    return (
        current is not None
        and current[1] == identity.start_time_ticks
        and process_state(identity.pid) not in (None, "Z")
    )


def matching_processes(processes: Sequence[ProcessIdentity]) -> List[ProcessIdentity]:
    return [identity for identity in processes if identity_matches(identity)]


def signal_matching_processes(processes: Sequence[ProcessIdentity], sig: signal.Signals) -> int:
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        raise CleanupError(
            "safe escalation requires Linux pidfd_open and pidfd_send_signal support"
        )

    count = 0
    # Descendant PIDs tend to be larger; reverse PID order is a conservative
    # post-order approximation after the complete identity set was captured.
    for identity in sorted(processes, key=lambda item: item.pid, reverse=True):
        if not identity_matches(identity):
            continue
        try:
            pidfd = os.pidfd_open(identity.pid, 0)
        except (ProcessLookupError, PermissionError, OSError):
            continue
        try:
            # Recheck the start time after opening the pidfd. If PID reuse raced
            # with pidfd_open, the new identity is rejected. Once verified, the
            # pidfd prevents a later reuse from redirecting the signal.
            if not identity_matches(identity):
                continue
            signal.pidfd_send_signal(pidfd, sig, None, 0)
        except (ProcessLookupError, PermissionError, OSError):
            continue
        finally:
            os.close(pidfd)
        count += 1
    return count


def process_owner_map() -> Dict[int, List[ProcessIdentity]]:
    identities = all_process_identities()
    owners: Dict[int, List[ProcessIdentity]] = {}
    for identity in identities.values():
        fd_dir = PROC_ROOT / str(identity.pid) / "fd"
        try:
            entries = list(fd_dir.iterdir())
        except OSError:
            continue
        for entry in entries:
            try:
                target = os.readlink(entry)
            except OSError:
                continue
            if not (target.startswith("socket:[") and target.endswith("]")):
                continue
            try:
                inode = int(target[8:-1])
            except ValueError:
                continue
            owners.setdefault(inode, []).append(identity)
    return owners


def potentially_conflicting(current: SocketEndpoint, captured: SocketEndpoint) -> bool:
    if captured.protocol == "unix":
        return (
            current.protocol == "unix"
            and current.unix_abstract == captured.unix_abstract
            and current.unix_path == captured.unix_path
        )
    if current.protocol != captured.protocol or current.local_port != captured.local_port:
        return False
    if current.family == captured.family:
        wildcard = "0.0.0.0" if captured.family == "ipv4" else "::"
        return (
            current.local_address == captured.local_address
            or current.local_address == wildcard
            or captured.local_address == wildcard
        )
    # IPv6 wildcard sockets may be dual-stack. Include same-port cross-family
    # owners in diagnostics; the actual bind probe decides reusability.
    return current.local_address == "::" or captured.local_address == "::"


def unrelated_conflicts(
    captured: SocketEndpoint,
    captured_keys: Set[Tuple[int, int]],
    table: Mapping[int, SocketEndpoint],
    owners: Mapping[int, List[ProcessIdentity]],
) -> List[Tuple[SocketEndpoint, ProcessIdentity]]:
    conflicts: List[Tuple[SocketEndpoint, ProcessIdentity]] = []
    for inode, current in table.items():
        if not potentially_conflicting(current, captured):
            continue
        for owner in owners.get(inode, ()): 
            if owner.key not in captured_keys:
                conflicts.append((current, owner))
    return conflicts


def endpoint_requires_reuse(endpoint: SocketEndpoint) -> bool:
    if endpoint.protocol == "unix":
        return bool(endpoint.unix_path)
    return endpoint.local_port not in (None, 0)


def format_endpoint(endpoint: SocketEndpoint) -> str:
    if endpoint.protocol == "unix":
        kind = "abstract" if endpoint.unix_abstract else "filesystem"
        return f"unix/{kind}:{endpoint.unix_path or '<unnamed>'}"
    return (
        f"{endpoint.protocol}/{endpoint.family}:"
        f"{endpoint.local_address}:{endpoint.local_port}"
    )


def remove_matching_stale_unix_file(endpoint: SocketEndpoint, invoking_uid: int) -> Optional[str]:
    path_text = endpoint.unix_path
    if not path_text or endpoint.unix_abstract:
        return None
    path = Path(path_text)
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise CleanupError(f"cannot inspect Unix socket path {path}: {exc}") from exc

    if not stat.S_ISSOCK(info.st_mode):
        raise UnrelatedEndpointOwner(
            f"captured Unix socket path now exists as a non-socket: {path}"
        )
    if info.st_uid != invoking_uid:
        raise UnrelatedEndpointOwner(
            f"captured Unix socket path is owned by UID {info.st_uid}, not current UID {invoking_uid}: {path}"
        )
    if endpoint.filesystem_device is None or endpoint.filesystem_inode is None:
        raise UnrelatedEndpointOwner(
            f"cannot prove that existing Unix socket path belongs to the captured run: {path}"
        )
    if (info.st_dev, info.st_ino) != (
        endpoint.filesystem_device,
        endpoint.filesystem_inode,
    ):
        raise UnrelatedEndpointOwner(
            f"Unix socket path was replaced after capture and will not be removed: {path}"
        )

    path.unlink()
    return str(path)


def probe_endpoint(endpoint: SocketEndpoint) -> Tuple[bool, Optional[str]]:
    if endpoint.protocol == "unix":
        if not endpoint.unix_path:
            return True, None
        address = (
            "\0" + endpoint.unix_path[1:]
            if endpoint.unix_abstract and endpoint.unix_path.startswith("@")
            else endpoint.unix_path
        )
        unix_types = {
            "0001": socket.SOCK_STREAM,
            "0002": socket.SOCK_DGRAM,
            "0005": getattr(socket, "SOCK_SEQPACKET", socket.SOCK_STREAM),
        }
        probe = socket.socket(
            socket.AF_UNIX, unix_types.get(endpoint.sock_type, socket.SOCK_STREAM)
        )
        try:
            probe.bind(address)
        except OSError as exc:
            return False, f"{exc.strerror} (errno {exc.errno})"
        finally:
            probe.close()
        if not endpoint.unix_abstract:
            try:
                Path(endpoint.unix_path).unlink()
            except FileNotFoundError:
                pass
        return True, None

    family = socket.AF_INET if endpoint.family == "ipv4" else socket.AF_INET6
    sock_type = socket.SOCK_STREAM if endpoint.protocol == "tcp" else socket.SOCK_DGRAM
    probe = socket.socket(family, sock_type)
    try:
        if family == socket.AF_INET6:
            address = (endpoint.local_address or "::", endpoint.local_port or 0, 0, 0)
        else:
            address = (endpoint.local_address or "0.0.0.0", endpoint.local_port or 0)
        probe.bind(address)
    except OSError as exc:
        return False, f"{exc.strerror} (errno {exc.errno})"
    finally:
        probe.close()
    return True, None


def write_process_report(path: Path, processes: Sequence[ProcessIdentity]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        handle.write("pid\tstart_time_ticks\tppid\tcommand\n")
        for item in processes:
            command = item.command.replace("\t", " ").replace("\n", " ")
            handle.write(
                f"{item.pid}\t{item.start_time_ticks}\t{item.ppid}\t{command}\n"
            )


def write_socket_report(
    path: Path,
    endpoints: Sequence[SocketEndpoint],
    owners: Mapping[int, Set[Tuple[int, int]]],
) -> None:
    with path.open("w", encoding="utf-8") as handle:
        handle.write(
            "inode\tprotocol\tfamily\ttype\tlocal\tremote\tstate\tunix_path\towners_pid_start\n"
        )
        for endpoint in endpoints:
            local = (
                f"{endpoint.local_address}:{endpoint.local_port}"
                if endpoint.protocol != "unix"
                else ""
            )
            remote = (
                f"{endpoint.remote_address}:{endpoint.remote_port}"
                if endpoint.protocol != "unix"
                else ""
            )
            owner_text = ",".join(
                f"{pid}:{start}" for pid, start in sorted(owners.get(endpoint.inode, set()))
            )
            handle.write(
                "\t".join(
                    (
                        str(endpoint.inode),
                        endpoint.protocol,
                        endpoint.family,
                        endpoint.sock_type,
                        local,
                        remote,
                        endpoint.state or "",
                        endpoint.unix_path or "",
                        owner_text,
                    )
                )
                + "\n"
            )


def state_to_json(
    processes: Sequence[ProcessIdentity],
    endpoints: Sequence[SocketEndpoint],
    owners: Mapping[int, Set[Tuple[int, int]]],
) -> Dict[str, object]:
    return {
        "format_version": 1,
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "boot_id": boot_id(),
        "uid": os.getuid(),
        "processes": [dataclasses.asdict(item) for item in processes],
        "sockets": [
            {
                **dataclasses.asdict(item),
                "owners": [list(key) for key in sorted(owners.get(item.inode, set()))],
            }
            for item in endpoints
        ],
    }


def load_state(path: Path) -> Tuple[int, List[ProcessIdentity], List[SocketEndpoint]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("format_version") != 1:
        raise CleanupError(f"unsupported cleanup-state format in {path}")
    captured_boot_id = str(data.get("boot_id", "unknown"))
    current_boot_id = boot_id()
    if captured_boot_id != "unknown" and current_boot_id != captured_boot_id:
        raise CleanupError("system boot ID changed after resource capture")
    processes = [ProcessIdentity(**item) for item in data.get("processes", [])]
    sockets = []
    for item in data.get("sockets", []):
        item = dict(item)
        item.pop("owners", None)
        sockets.append(SocketEndpoint(**item))
    return int(data.get("uid", -1)), processes, sockets


def write_metric(path: Path, value: float) -> None:
    path.write_text(f"{value:.9f}\n", encoding="utf-8")


def write_cleanup_metrics(metrics_dir: Path, measurements: CleanupMeasurements) -> None:
    metrics_dir.mkdir(parents=True, exist_ok=True)
    write_metric(metrics_dir / "pre_restore_cleanup_seconds.txt", measurements.total_seconds)
    write_metric(
        metrics_dir / "original_shutdown_seconds.txt",
        measurements.process_shutdown_seconds,
    )
    write_metric(
        metrics_dir / "pre_restore_endpoint_verification_seconds.txt",
        measurements.endpoint_verification_seconds,
    )
    write_metric(
        metrics_dir / "pre_restore_final_grace_seconds.txt",
        measurements.final_grace_seconds,
    )
    (metrics_dir / "pre_restore_cleanup_status.txt").write_text(
        "SUCCESS\n", encoding="utf-8"
    )
    (metrics_dir / "pre_restore_cleanup_removed_unix_sockets.txt").write_text(
        "".join(f"{path}\n" for path in measurements.stale_unix_socket_files_removed),
        encoding="utf-8",
    )


def cleanup_resources(
    state_path: Path,
    timeout: float,
    poll: float,
    force_kill_after: float,
    force_kill_grace: float,
    final_grace: float,
    report_interval: float,
    metrics_dir: Path,
) -> CleanupMeasurements:
    captured_uid, processes, endpoints = load_state(state_path)
    if captured_uid != os.getuid():
        raise CleanupError(
            f"cleanup state was captured by UID {captured_uid}, current UID is {os.getuid()}"
        )

    captured_keys = {identity.key for identity in processes}
    start = monotonic()
    deadline = start + timeout
    next_report = start
    term_at = start + force_kill_after
    kill_at: Optional[float] = None
    term_sent = False
    kill_sent = False

    while True:
        now = monotonic()
        survivors = matching_processes(processes)
        if not survivors:
            break
        if now >= deadline:
            details = ", ".join(
                f"{item.pid}:{item.start_time_ticks} {item.command}" for item in survivors
            )
            raise CleanupTimeout(f"captured processes still alive at timeout: {details}")
        if not term_sent and now >= term_at:
            sent = signal_matching_processes(survivors, signal.SIGTERM)
            print(f"[adaptive-cleanup] Sent TERM to {sent} captured process(es).", flush=True)
            term_sent = True
            kill_at = now + force_kill_grace
        elif term_sent and not kill_sent and kill_at is not None and now >= kill_at:
            sent = signal_matching_processes(survivors, signal.SIGKILL)
            print(f"[adaptive-cleanup] Sent KILL to {sent} captured process(es).", flush=True)
            kill_sent = True
        if now >= next_report:
            print(
                f"[adaptive-cleanup] Waiting for {len(survivors)} captured process(es) to disappear.",
                flush=True,
            )
            next_report = now + report_interval
        time.sleep(min(poll, max(0.0, deadline - now)))

    process_done = monotonic()
    print("[adaptive-cleanup] All captured processes have disappeared.", flush=True)

    removed_paths: List[str] = []
    pending: Dict[Tuple[object, ...], SocketEndpoint] = {
        endpoint.signature(): endpoint
        for endpoint in endpoints
        if endpoint_requires_reuse(endpoint)
    }
    next_report = process_done

    while pending:
        now = monotonic()
        if now >= deadline:
            remaining = ", ".join(format_endpoint(item) for item in pending.values())
            raise CleanupTimeout(f"captured endpoints were not reusable at timeout: {remaining}")

        blocked: MutableMapping[Tuple[object, ...], SocketEndpoint] = {}
        blocked_reasons: List[str] = []
        current_table = current_socket_table()
        current_owners = process_owner_map()
        for signature, endpoint in pending.items():
            conflicts = unrelated_conflicts(
                endpoint, captured_keys, current_table, current_owners
            )
            if conflicts:
                descriptions = "; ".join(
                    f"PID {owner.pid} start {owner.start_time_ticks} ({owner.command}) owns {format_endpoint(current)}"
                    for current, owner in conflicts
                )
                raise UnrelatedEndpointOwner(
                    f"captured endpoint {format_endpoint(endpoint)} is occupied by an unrelated process: {descriptions}"
                )

            if endpoint.protocol == "unix" and not endpoint.unix_abstract:
                removed = remove_matching_stale_unix_file(endpoint, captured_uid)
                if removed is not None:
                    removed_paths.append(removed)
                    print(
                        f"[adaptive-cleanup] Removed captured stale Unix socket file: {removed}",
                        flush=True,
                    )

            reusable, reason = probe_endpoint(endpoint)
            if not reusable:
                blocked[signature] = endpoint
                blocked_reasons.append(f"{format_endpoint(endpoint)}: {reason}")

        pending = dict(blocked)
        if not pending:
            break
        if now >= next_report:
            #print(
            #    "[adaptive-cleanup] Waiting for endpoint reuse: "
            #    + " | ".join(blocked_reasons),
            #    flush=True,
            #)
            print(
                f"[adaptive-cleanup] Waiting for {len(blocked)} endpoint(s) to become reusable...",
                flush=True,
            )
            next_report = now + report_interval
        time.sleep(min(poll, max(0.0, deadline - now)))

    endpoints_done = monotonic()
    print("[adaptive-cleanup] All captured socket endpoints are reusable.", flush=True)

    if final_grace > 0:
        if monotonic() + final_grace > deadline:
            raise CleanupTimeout("insufficient cleanup timeout remaining for final grace delay")
        print(
            f"[adaptive-cleanup] Applying final verified-clear grace delay of {final_grace:g} seconds.",
            flush=True,
        )
        time.sleep(final_grace)

    end = monotonic()
    measurements = CleanupMeasurements(
        total_seconds=end - start,
        process_shutdown_seconds=process_done - start,
        endpoint_verification_seconds=endpoints_done - process_done,
        final_grace_seconds=end - endpoints_done,
        term_sent=term_sent,
        kill_sent=kill_sent,
        stale_unix_socket_files_removed=removed_paths,
    )
    write_cleanup_metrics(metrics_dir, measurements)
    return measurements


def capture_command(args: argparse.Namespace) -> int:
    roots = list(dict.fromkeys(args.root_pid))
    processes = capture_process_tree(roots)
    endpoints, owners = capture_socket_endpoints(processes)
    args.state.parent.mkdir(parents=True, exist_ok=True)
    args.state.write_text(
        json.dumps(state_to_json(processes, endpoints, owners), indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
    write_process_report(args.process_report, processes)
    write_socket_report(args.socket_report, endpoints, owners)
    print(
        f"[adaptive-cleanup] Captured {len(processes)} process identity/identities and "
        f"{len(endpoints)} socket endpoint(s).",
        flush=True,
    )
    return 0


def cleanup_command(args: argparse.Namespace) -> int:
    try:
        measurements = cleanup_resources(
            state_path=args.state,
            timeout=args.timeout,
            poll=args.poll,
            force_kill_after=args.force_kill_after,
            force_kill_grace=args.force_kill_grace,
            final_grace=args.final_grace,
            report_interval=args.report_interval,
            metrics_dir=args.metrics_dir,
        )
    except UnrelatedEndpointOwner as exc:
        args.metrics_dir.mkdir(parents=True, exist_ok=True)
        (args.metrics_dir / "pre_restore_cleanup_status.txt").write_text(
            "FAILED_UNRELATED_ENDPOINT_OWNER\n", encoding="utf-8"
        )
        (args.metrics_dir / "pre_restore_cleanup_failure.txt").write_text(
            f"{exc}\n", encoding="utf-8"
        )
        print(f"ERROR: {exc}", file=sys.stderr)
        return 20
    except CleanupTimeout as exc:
        args.metrics_dir.mkdir(parents=True, exist_ok=True)
        (args.metrics_dir / "pre_restore_cleanup_status.txt").write_text(
            "FAILED_TIMEOUT\n", encoding="utf-8"
        )
        (args.metrics_dir / "pre_restore_cleanup_failure.txt").write_text(
            f"{exc}\n", encoding="utf-8"
        )
        print(f"ERROR: {exc}", file=sys.stderr)
        return 21
    except (CleanupError, OSError, ValueError, json.JSONDecodeError) as exc:
        args.metrics_dir.mkdir(parents=True, exist_ok=True)
        (args.metrics_dir / "pre_restore_cleanup_status.txt").write_text(
            "FAILED_ERROR\n", encoding="utf-8"
        )
        (args.metrics_dir / "pre_restore_cleanup_failure.txt").write_text(
            f"{exc}\n", encoding="utf-8"
        )
        print(f"ERROR: {exc}", file=sys.stderr)
        return 22

    print(
        f"[adaptive-cleanup] Completed in {measurements.total_seconds:.3f} seconds.",
        flush=True,
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    capture = subparsers.add_parser("capture", help="capture exact process and socket state")
    capture.add_argument("--root-pid", type=int, action="append", required=True)
    capture.add_argument("--state", type=Path, required=True)
    capture.add_argument("--process-report", type=Path, required=True)
    capture.add_argument("--socket-report", type=Path, required=True)
    capture.set_defaults(func=capture_command)

    cleanup = subparsers.add_parser("cleanup", help="release and verify captured resources")
    cleanup.add_argument("--state", type=Path, required=True)
    cleanup.add_argument("--metrics-dir", type=Path, required=True)
    cleanup.add_argument("--timeout", type=parse_positive_float, required=True)
    cleanup.add_argument("--poll", type=parse_positive_float, required=True)
    cleanup.add_argument("--force-kill-after", type=parse_nonnegative_float, required=True)
    cleanup.add_argument("--force-kill-grace", type=parse_nonnegative_float, required=True)
    cleanup.add_argument("--final-grace", type=parse_nonnegative_float, required=True)
    cleanup.add_argument("--report-interval", type=parse_positive_float, required=True)
    cleanup.set_defaults(func=cleanup_command)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except CleanupError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
