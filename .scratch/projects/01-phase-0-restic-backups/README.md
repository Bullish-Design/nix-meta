# Phase 0 — restic system backups

**Status:** PASSED. All five gate conditions hold: a successful snapshot,
a repository check, the exact restore gate, `EVIDENCE.md` recording it,
and the changes landed and pushed.
**Opened:** 2026-10-01
**Closed:** 2026-10-04
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
| `NEXT-SESSION-KICKOFF.md` | the kickoff prompt for the next working session — investigate and plan the remaining work |
| `REVIEW-PROMPT.md` | the kickoff prompt for a review session — audit what landed, then report state and next steps |

## The gate

Phase 0 is complete. All five conditions hold:

1. `restic snapshots` lists a successful snapshot. **MET** — two
   snapshots, `3dd34831` and `26236227`. See `EVIDENCE.md` §16.
2. A repository check succeeds. **MET** — `restic-check-system.service`
   succeeded 2026-10-04 04:10:47 EDT. See `EVIDENCE.md` §16.
3. The restore gate restores three exact files and `cmp` matches each.
   **MET** — see `EVIDENCE.md` §16.
4. `EVIDENCE.md` records the result. **MET** — `EVIDENCE.md` §16.
5. The repository changes have landed and been pushed. **MET** — see
   `EVIDENCE.md` §8 and §16. The tag and the re-pin are also done.

## What is done

- `nix-secrets` is CANONICAL again. A rewound release left its trunk behind its
  own `v0.1.0` tag; see `DESIGN.md` §8.
- `scripts/secret-add` no longer puts a secret in a process argument.
- `scripts/secret-ls` lists all ten canonical names.
- `RUNBOOK.md` §3a states the recipient-coverage problem.
- `profiles/backup.nix` exists, is exported, and is in the `server`
  composition. Both halves of nix-meta's verify gate pass.
- The repository is passwordless: every restic invocation carries
  `--insecure-no-password`, injected by a wrapped restic package. There is
  no secret to provision and no secret-arrival gate. See `DESIGN.md` §2.
  The profile creates real backup, check and health units as soon as it is
  enabled and activated — nothing waits on a secret any more.
- The `profiles/backup.nix` profile and the Phase 0 documents have landed on
  `nix-meta` trunk and reached origin. See `EVIDENCE.md` §8.
- The target is decided: `/mnt/wd_green1/restic`, the repository that already
  exists there. The user's decision, recorded in `DESIGN.md` §1. The WD
  Green's age and load-cycle count are an accepted risk; a NAS is planned as
  a second copy location later.
- `machines/server.nix` sets `nix-meta.backup.enable = true` with
  `mountPoint = "/mnt/wd_green1"`. The host's live generation is now 134,
  store path
  `rgzc6m0z55iygpjzbs6g87xh66k87c8b-nixos-system-server-26.11.20260705.d407951`.
  The units exist and have run: two snapshots, a successful check, and a
  passed restore gate. See `EVIDENCE.md` §16.

## No blocker remains

B2 (interactive `sudo`) is resolved: the operator ran the privileged steps
directly, on 2026-10-04. See `IMPLEMENTATION.md` step B2 and `EVIDENCE.md`
§16. B3 (an off-host SOPS recipient) is resolved, not merely deferred: the
passwordless design removed the secret that recipient would have
protected. See `DESIGN.md` §2 and §3.
