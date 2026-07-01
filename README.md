# zync

[![CI](https://github.com/floatdrop/zync/actions/workflows/ci.yml/badge.svg)](https://github.com/floatdrop/zync/actions/workflows/ci.yml)

A modern [rsync](https://rsync.samba.org/) alternative, written in [Zig](https://ziglang.org/).

zync synchronises files and directory trees — locally or between hosts over SSH —
using a delta-transfer algorithm so that only the changed parts of changed files
cross the wire. It aims to keep rsync's proven ideas (rolling-checksum deltas,
quick-check, mirror deletion) while modernising the parts that have aged:
multi-core parallelism, a memory-safe implementation, faster hashing, and an
async I/O core built on Zig 0.16's `std.Io`.

> **Status: early / work in progress.** The core works and is tested end to end,
> but zync is not yet a drop-in rsync replacement. See [Limitations](#limitations).

## Why

rsync is single-threaded (one core, one TCP stream), leans on mtime heuristics,
uses dated MD4/MD5 checksums, has a long C-codebase CVE history, and only syncs
one way. zync explores what a from-scratch alternative looks like:

- **Parallel by default** — local syncs fan out across all CPU cores.
- **Content-verified** — every reconstructed file is checked with BLAKE3 end to end.
- **Memory-safe** — written in Zig, no buffer-overflow class of bugs.
- **Async core** — built on `std.Io` (io_uring-capable) rather than blocking I/O.

## Features

- **Delta transfer** — rolling weak checksum + BLAKE3 strong hash; only changed
  blocks (and literal runs) are sent. Matches short trailing blocks too.
- **Constant memory** — files are streamed through a bounded window and basis
  blocks are read on demand, so even multi-gigabyte files sync in a few MiB of
  RAM (a 1 GiB delta peaks at ~2 MiB).
- **Three transports** — local ↔ local, push (`./src host:/dst`), pull (`host:/src ./dst`).
- **Quick-check** — unchanged files (size + mtime + perms) are skipped.
- **Parallel local sync** — bounded worker pool, one file per core (`-j`).
- **Parallel remote transfers** — shard files across several SSH connections
  (`--conns`), for push *and* pull, for concurrent CPU on both ends and multiple
  TCP streams.
- **Special files** — FIFOs, sockets, and (with privilege) device nodes are
  replicated (Linux).
- **Exclude filters** (`--exclude`) — skip paths by glob; excluded directories
  aren't even walked.
- **Compression** (`-z`) — deflate the transferred data for slow/metered links.
- **Structured output** (`--json`) and per-file progress (`--progress`).
- **Hardlinks** (`-H`) — files sharing an inode are transferred once and the
  link structure is recreated (single-connection transfers).
- **Mirror deletion** (`--delete`) — remove destination entries the source dropped.
- **Metadata preservation** — permissions and mtimes for files and directories
  (including the destination root), owner/group (`-o`/`-g`), and extended
  attributes of files and directories (`-X`, which also carries ACLs and
  SELinux contexts stored as xattrs).
- **Symlinks** — preserved verbatim (targets copied, not dereferenced).
- **Atomic writes** — files land via a temp file + rename; an interrupted or
  failed transfer never leaves a half-written file.

## Requirements

- **Zig 0.16.0** (the project targets this exact release).
- **Linux or macOS.** The core sync, delta transfer, and owner/xattr
  preservation work on both. A few extras are Linux-only — see
  [Limitations](#limitations). zync is POSIX-oriented and assumes an SSH-style
  remote shell.
- For remote transfers: `ssh` (or any `--rsh` program) and a `zync` binary on
  the remote host.

## Build

```sh
zig build                      # debug binary at ./zig-out/bin/zync
zig build -Doptimize=ReleaseFast
zig build test                 # run the test suite
zig build run -- <args>        # build & run
```

## Usage

```
zync [options] <src> <dst>
```

`<src>` is a local path. `<dst>` is a local path or `[user@]host:path`.
(`<src>` may also be `host:path` for a pull.)

```sh
# Local mirror
zync ./photos /backup/photos

# Push to a remote host over SSH
zync ./site user@web01:/var/www/site

# Pull from a remote host
zync user@web01:/var/log/app ./logs

# Exact mirror: delete files on the destination that no longer exist in source
zync --delete ./src host:/dst

# Preserve owner, group, and extended attributes
zync -o -g -X ./data host:/data

# Force whole-file copies (skip delta), e.g. for local SSDs
zync -W ./src ./dst

# Control parallelism for a local sync
zync -j 16 ./huge-tree ./backup
```

### Options

| Flag | Meaning |
|------|---------|
| `-v, --verbose` | Log each file as it is sent or skipped |
| `-P, --progress` | Show each file as it transfers |
| `--json` | Print the final summary as JSON (to stdout) |
| `--exclude <pat>` | Skip paths matching `<pat>` (repeatable) |
| `-z, --compress` | Compress the wire (remote; not with `--conns > 1`) |
| `-W, --whole-file` | Disable delta; always copy changed files whole |
| `--delete` | Delete destination entries missing from the source |
| `-o, --owner` | Preserve owning user (best-effort; needs privilege) |
| `-g, --group` | Preserve owning group (best-effort; needs privilege) |
| `-X, --xattrs` | Preserve extended attributes of files (best-effort) |
| `-j, --jobs <n>` | Parallel workers for local sync (default: CPU count) |
| `--conns <n>` | Parallel SSH connections for a remote push (default: 1) |
| `--rsh <cmd>` | Remote shell program (default: `ssh`) |
| `--remote-zync <p>` | `zync` program name on the remote (default: `zync`) |

`zync --server <path>` is the remote peer, spoken over stdio; you normally never
invoke it directly — the client spawns it via `--rsh`.

## How it works

For a push, the client holds the source and the server holds the destination
(pull inverts the roles). Per file:

1. The client sends a file header (path, size, mtime, perms).
2. The server **quick-checks** its copy — if unchanged, it replies *skip*.
3. Otherwise the server splits its copy into blocks and sends a **signature**
   (a weak rolling checksum + a BLAKE3 hash per block).
4. The client slides a rolling window over the source, matching windows against
   the signature, and streams a **delta**: `copy block N` / `literal bytes`.
5. The server **reconstructs** the file, verifies it against a whole-file BLAKE3
   hash, and writes it atomically.

Local syncs run the same pipeline in-process, fanned out across a worker pool.

The delta engine is covered by a randomised round-trip property test:
`patch(old, delta(signature(old), new)) == new` over hundreds of random edits.

## Architecture

```
src/
  main.zig            CLI entry: parse, pick mode, dispatch
  root.zig            library public API

  cli/args.zig        command-line parsing
  core/
    endpoint.zig      [user@]host:path parsing
    sync.zig          local sync driver (parallel worker pool)
    session.zig       sender / receiver roles over the wire protocol
    parallel.zig      parallel push across multiple SSH connections
  delta/
    rolling.zig       weak rolling checksum
    signature.zig     per-block signatures, block-size selection
    table.zig         weak-checksum → block lookup
    stream.zig        streaming matcher (bounded memory)
    delta.zig         in-memory matcher (used by tests)
    patch.zig         apply ops + verify
  hash/strong.zig     BLAKE3 (block + whole-file)
  proto/wire.zig      framing, varints, message tags, handshake flags
  fs/
    link.zig          symlink replication
    special.zig       FIFOs / sockets / device nodes
    hardlink.zig      hardlink detection + replication
    meta.zig          directory perms/mtime (+owner) preservation
    owner.zig         uid/gid read (statx) + apply (fchownat)
    xattr.zig         extended attributes
    prune.zig         --delete of extraneous entries
```

The library (`root.zig`) holds all logic and is separate from the thin CLI
(`main.zig`), so the core is testable and embeddable.

## Limitations

zync is young. Known gaps versus rsync:

- **macOS is second-class in a few spots.** Core sync, delta transfer,
  owner/group (`-o`/`-g`), and xattrs (`-X`) work on both Linux and macOS.
  Special files (`mknodat`) are Linux-only, and hardlink detection on macOS
  is inode-only (no cross-device disambiguation), which is fine for a
  single-filesystem tree.
- **Hardlinks (`-H`) are single-connection only** — not supported together with
  `--conns > 1` (rejected with an error).
- **Xattrs cover files and directories, not symlinks** (filesystems rarely
  support symlink xattrs). ACLs/SELinux ride along as xattrs but there is no
  dedicated, portable ACL handling.
- **Owner/group and xattrs are best-effort** — applying them needs privilege;
  failures are skipped, not reported as errors.
- **One-way only** — no bidirectional sync or conflict resolution.
- **No resume** of an interrupted whole-tree transfer, no reflink/CoW
  awareness, no compression, and only one endpoint may be remote.

## Roadmap

Priorities weigh value for the core use case (syncing trees between hosts,
backups, deploys) against effort. The previous "high priority" tier — exclude
filters, wire compression, and progress/JSON output — has shipped.

### Medium — scaling & robustness

- **Resume** of an interrupted whole-tree transfer.
- **Reflink / CoW copies** (`FICLONE`) for near-instant local backups on
  btrfs/XFS.
- **Bandwidth limit** (`--bwlimit`).

### Lower — efficiency refinements & niches

- **Full in-protocol mux** — multiplex many files over a single connection
  (incremental over `--conns`; a larger protocol rewrite).
- **Hardlinks with `--conns`** — canonical-master coordination across shards.
- **Both-endpoints-remote**, symlink xattrs, dedicated portable ACL handling.

## License

[MIT](LICENSE) © Vsevolod Strukchinsky
