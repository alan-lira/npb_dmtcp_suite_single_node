#!/usr/bin/env python3

"""Controlled validation of the socket-buffer semantics used by the DMTCP patch."""

from __future__ import annotations

import socket


def main() -> int:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)

    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client.connect(listener.getsockname())
    server, _ = listener.accept()

    try:
        original = server.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
        required = original + 64 * 1024
        server.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, required)
        expanded = server.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
        if expanded < required:
            raise AssertionError(
                f"normal SO_RCVBUF growth was capped below the controlled "
                f"requirement: original={original}, required={required}, "
                f"expanded={expanded}"
            )

        restore_request = max(1, original // 2)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, restore_request)
        restored = server.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
        if restored != original:
            raise AssertionError(
                f"SO_RCVBUF restore mismatch: original={original}, restored={restored}"
            )
    finally:
        server.close()
        client.close()
        listener.close()

    print("Controlled receive-buffer expansion/restoration test passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
