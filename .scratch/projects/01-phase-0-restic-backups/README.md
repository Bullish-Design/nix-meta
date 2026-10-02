# Phase 0 — restic system backups

**Status:** BLOCKED on three operator actions. The repository work is done and verified.
**Opened:** 2026-10-01
**Host:** `server` (Dell Precision 5820, Xeon W-2125, 128 GB RAM)
**Parent project:** `vendomat/.scratch/projects/07-local-depot-release-bus/IMPLEMENTATION.md`, Phase 0

## Why this exists

There are no verified backups of this host. Every later phase of the local
depot and release bus is a disk operation. Phase 0 comes first.

The documents live in `nix-meta` because `nix-meta` owns the backup profile,
the systemd units, activation, and the restore gate. `vendomat` keeps the
umbrella guide.

## Where things are

| Document | Holds |
|---|---|
| `DESIGN.md` | the decisions, with `file:line` anchors |
| `IMPLEMENTATION.md` | the ordered steps, and which are done |
| `EVIDENCE.md` | measured facts, verification output, and the gate |

## The gate

Phase 0 is complete only when all five hold:

1. `restic snapshots` lists a successful snapshot.
2. A repository check succeeds.
3. The restore gate restores three exact files and `cmp` matches each.
4. `EVIDENCE.md` records the result.
5. The repository changes have landed and been pushed.

None of the five hold yet. See "What blocks this" below.

## What is done

- `nix-secrets` is CANONICAL again. A rewound release left its trunk behind its
  own `v0.1.0` tag; see `DESIGN.md` §8.
- `scripts/secret-add` no longer puts a secret in a process argument.
- `scripts/secret-ls` lists all ten canonical names.
- `RUNBOOK.md` §3a states the recipient-coverage problem.
- `profiles/backup.nix` exists, is exported, and is in the `server`
  composition. Both halves of nix-meta's verify gate pass.
- The profile creates **no units** until an operator turns it on. Nothing on
  the host changed.

## What blocks this

| Blocker | Needs | Document |
|---|---|---|
| No WD Re disk is connected | a physical action | `IMPLEMENTATION.md` step B1 |
| `sudo` requires a password | an interactive session | step B2 |
| No off-host SOPS recipient exists | a decision and a key | step B3 |

The third is the one that matters most. Both current recipients of the
encrypted store live on this one host. A `restic-password` that only this host
can decrypt cannot recover this host.
