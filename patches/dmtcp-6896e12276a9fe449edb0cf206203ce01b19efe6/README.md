# DMTCP patch bundle for commit 6896e12276a9fe449edb0cf206203ce01b19efe6

These assets are valid only for the DMTCP commit named by this directory.
`scripts/install_dmtcp_mpich_env.sh` verifies each patch checksum before
changing the checked-out source.

## `connectionrewirer-backlog-1024.exact.patch`

A strict exact-substitution patch for:

```text
src/plugin/ipc/socket/connectionrewirer.cpp
```

It changes the primary IPv4 `JServerSocket`, IPv6, Unix-stream, and
Unix-seqpacket restore-listener backlogs from `32` to `1024`. Every `FROM`
value must occur exactly once, every `TO`
value must initially be absent, and all replacements are verified afterward.
Any mismatch stops installation.

## `kernelbufferdrainer-duplex-refill.patch`

A standard unified diff for:

```text
src/plugin/ipc/socket/kernelbufferdrainer.cpp
```

It replaces the blocking two-phase stream-buffer refill with a
receive-capacity-aware nonblocking duplex state machine. Before refill, each
stream verifies that its reconstructed receive buffer can hold the saved data
that the peer must echo back. It first uses `SO_RCVBUF`, falls back to
`SO_RCVBUFFORCE` when the normal kernel limit is insufficient, and restores the
original buffer setting after refill. The installer requires the known original
source checksum, applies the patch with `--forward` and zero fuzz, and verifies
the exact patch checksum and implementation markers.

Neither patch is intended for another DMTCP revision.
