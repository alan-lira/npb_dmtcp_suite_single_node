#!/usr/bin/env python3

"""Controlled validation of socket-buffer semantics used by the DMTCP patch."""

from __future__ import annotations

import socket
import sys

import pytest


pytestmark = pytest.mark.skipif(
    sys.platform != "linux",
    reason="the DMTCP receive-buffer contract targets Linux socket semantics",
)


def test_receive_buffer_can_expand_and_restore() -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)

        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
            client.settimeout(5)
            client.connect(listener.getsockname())
            server, _ = listener.accept()
            with server:
                original = server.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
                required = original + 64 * 1024
                server.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, required)
                expanded = server.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
                assert expanded >= required, (
                    "normal SO_RCVBUF growth was capped below the controlled "
                    f"requirement: original={original}, required={required}, "
                    f"expanded={expanded}"
                )

                # Linux reports twice the user-requested SO_RCVBUF value. Asking
                # for half the observed original should therefore restore it.
                restore_request = max(1, original // 2)
                server.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, restore_request)
                restored = server.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
                assert restored == original, (
                    f"SO_RCVBUF restore mismatch: original={original}, restored={restored}"
                )


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__]))
