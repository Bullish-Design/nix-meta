# Kickoff: Phase 0 restic backups — investigate and plan only

Your job is to investigate and plan. Do not implement. Do not run any command
that changes the host, a secret store, or a repository's history. Read,
measure where you safely can without root, and reason. End the session with a
written plan and a short list of decisions you need from the user. Do not
touch `sudo`, `nixos-rebuild`, `restic`, `sops`, or any `gitman land` /
`gitman push` / `gitman release` command. Read-only `gitman status` and
`gitman doctor` are fine.

## Read these first

| Document | Primary path | Fallback if landed to trunk |
|---|---|---|
| Phase 0 README | `~/Documents/Projects/nix-meta/.worktrees/phase-0-restic-backups/.scratch/projects/01-phase-0-restic-backups/README.md` | `~/Documents/Projects/nix-meta/.scratch/projects/01-phase-0-restic-backups/README.md` |
| Phase 0 design decisions | same dir, `DESIGN.md` | same fallback dir |
| Phase 0 ordered steps | same dir, `IMPLEMENTATION.md` | same fallback dir |
| Phase 0 measured evidence | same dir, `EVIDENCE.md` | same fallback dir |
| The backup profile | `~/Documents/Projects/nix-meta/.worktrees/phase-0-restic-backups/profiles/backup.nix` | `~/Documents/Projects/nix-meta/profiles/backup.nix` |
| Umbrella guide | `~/Documents/Projects/vendomat/.scratch/projects/07-local-depot-release-bus/IMPLEMENTATION.md` — read Phase 0 and Phases A–F, section 6 "Open decisions", section 7 "Working rules" |
| Repo instructions | `~/Documents/Projects/nix-meta/CLAUDE.md`, `~/Documents/Projects/nix-secrets/AGENTS.md` |

The Phase 0 lane has already landed into `nix-meta` trunk; use the fallback
path if the primary path is missing. Do not run any `git` or `gitman`
command that mutates state while you check this.

Also read, before acting: the `gitman`, `writing`, and `my-ai` skills (or the
equivalent personal-layer skill files in this environment), and each
repository's own `AGENTS.md`.

## The two decisions that block everything

Phase 0 — restic backups for host `server` — is written and verified in the
repository, and the target disk is no longer an open question: the user
chose `/mnt/wd_green1/restic`, the repository that already exists there,
instead of waiting for a WD Re disk. `IMPLEMENTATION.md` step B1 is
**resolved by decision**, not by hardware; see `DESIGN.md` §1. Two operator
decisions remain. Work out, for each, what the user must decide and what
evidence would settle it. Do not decide for them; prepare the choice.

A NAS is planned as a **second copy location**, once one exists. Do not
treat it as solving the decision below — see the note after item 2.

1. **`sudo` needs an interactive password.** Every privileged step —
   mounting, `sops`, `nixos-rebuild` — needs root, and the current session
   cannot authenticate (`sudo -n true` refuses). This just needs a session
   where the user can type a password. Note it, do not try to work around
   it.

2. **No off-host SOPS recipient exists — the important one.** Both current
   recipients of the encrypted secrets store live on this one host:
   `&tower` from `/etc/ssh/ssh_host_ed25519_key`
   (`nix-secrets/secrets/.sops.yaml:30`) and `&author` from
   `~/.ssh/id_ed25519` (`:35`). The `restic-password` secret that protects
   the backup is encrypted to these two keys only. Lose the host and the
   backup cannot be opened — the recovery mechanism depends entirely on the
   thing it is meant to recover from. `DESIGN.md` §3 and `IMPLEMENTATION.md`
   step B3 lay out three options: an off-host age recipient on another
   machine, a hand-held age key kept off this box, or password-manager
   escrow with no third recipient (which `IMPLEMENTATION.md` warns leaves no
   way to decrypt the rest of the store after host loss). Lay out the
   trade-offs of each and recommend one, but let the user choose.

**The planned NAS does not resolve item 2.** A second copy on a NAS removes
single-disk risk, nothing more. Both copies would still be encrypted to
`restic-password`, and that secret is still encrypted only to the two
on-host keys above. Losing the host locks both copies, NAS copy included.
See `DESIGN.md` §1.

## Group 2 — steps that are written and unit-tested, but never run on the host

Five pieces of `profiles/backup.nix` — the preflight check, the failure
signal, the weekly check, the restore gate, and the `pg_dumpall` job — were
authored and tested in isolation (stubbed scripts, throwaway repositories,
forced module evaluation). None has run against the real host, because every
one of them needs root. Plan the order in which they should be proved once
`sudo` and a disk are available, and name what could still be wrong at each
step that isolated testing cannot catch (for example: real restic timing
against a 5400 rpm disk with ~107 GiB of source data, real systemd unit
interaction, real lock contention).

Call out two things specifically in your plan:

- The PostgreSQL dump (`nix-meta.backup.postgres.enable`, default off,
  `profiles/backup.nix:308-330` and `:549-607`) is shipped disabled and
  unproven. `/var/lib/postgresql` deliberately stays inside the plain file
  backup (`DESIGN.md` §9) until an operator runs
  `systemctl start restic-backups-postgres.service` and confirms a
  `pg_dumpall.sql` entry in the snapshot. Do not plan to exclude
  `/var/lib/postgresql` from the file backup before that proof exists —
  removing it early would leave the database with no coverage at all.
- Mnemonix Hindsight application consistency has **no solution at all**.
  The Docker volume `mnemonix-hindsight-data` is included in the file
  backup via `/var/lib/docker/volumes`, but a file-level restore of a live
  container's volume does not prove the application is consistent. This
  must be settled — at minimum, a described option — before Phase E, or the
  migrated host inherits an unverified data store.

## Group 3 — the open decisions in the umbrella guide, section 6

Summarize each of these and prepare a recommendation with trade-offs. Do not
decide; the user decides.

1. **Does the laptop need to resolve depot inputs?** `git+file:///srv/...`
   is local-only. `git+ssh://andrew@server.tail770f47.ts.net/srv/git/<x>.git`
   would work over the tailnet with no new software, since `sshd` already
   runs key-only on `tailscale0:22`. `file://` is simpler at install time.
   One form for all inputs, or two forms, are both viable.
2. **Do the roughly 47 non-DAG repos move to the depot too?** Only the ~25
   repos in `nix-meta`'s transitive closure strictly need to. Uniformity
   argues for moving all of them; the target drive has room for 100x the
   data either way.
3. **Cache signing versus `require-sigs false`.** A `file://` binary cache
   written by `nix copy` is unsigned by default. The umbrella guide prefers
   a local signing key over disabling signature checks, but this is unsettled.
4. **`/mnt/flex` and the two WD Re bays are unconnected.** They are declared
   in `machines/server.nix` but nothing is seated. The WD Re pair is no
   longer the open question it was: the user decided the Phase 0 backup
   target is `/mnt/wd_green1` (see above), and the WD Re pair stays the
   preferred upgrade path once a disk is connected and proved.
5. **Is Flora's training data still wanted?** About 119 GiB sits on
   `/mnt/shared` (`sdb2`) with no backup and no decision on whether to keep
   it, move it, or discard it. Nothing there has been touched.

## Group 4 — sequencing Phases B through F

Phase A (verify gates across the 24-repo DAG) is reported complete. Using the
current real state — not the umbrella guide's original 2026-09-28/29
inventory, which has already drifted once — produce a dependency-ordered
plan for Phases B through F. Identify which later phases Phase 0 genuinely
gates, and which it does not. Be specific:

- **Phase F stays blocked** until `/mnt/shared` has its own verified backup
  policy. That drive holds roughly 129 GiB of unadjudicated data (Flora's
  training data, an old `structured-agents-v2` copy, a pre-flake
  `configuration.nix`) and is explicitly out of Phase 0's scope.
- **Phase E must restore `/etc/ssh/ssh_host_ed25519_key`** (mode `0600`)
  before the first activation on the replacement system, or sops-nix cannot
  decrypt anything on the new install — a fresh install generates a new
  host key, and the age identity for the whole secrets store is derived from
  that exact file. The restore gate in `DESIGN.md` §7 / `IMPLEMENTATION.md`
  step C8 includes this file for exactly this reason.
- Decide, and state your reasoning, on which of B/C/D genuinely need Phase 0
  finished first versus which are independent and could proceed in parallel.

Note also: `nix-meta` may still carry two published Atuin lanes from another
session, `atuin-18-23-upgrade` and `atuin-18-23-upgrade+server-rpath`. Leave
them alone; do not fold them into your plan or touch them.

## Facts you do not need to re-measure

### Host and filesystems

| Item | Value |
|---|---|
| Host | `server`, Dell Precision 5820, Xeon W-2125, 128 GB RAM |
| OS | NixOS 26.11.20260705.d407951 |
| `/` and `/home` | one btrfs filesystem, `/dev/nvme1n1p3`, label `NIXROOT`: 444G total, 416G used, 26G free, **95% full** — treat as a live safety constraint |
| `/mnt/wd_green1` | `/dev/sda1`, ext4, 1.8T, 59G used |
| `/mnt/shared` | `/dev/sdb2`, ntfs3, 130G used (~129 GiB unadjudicated, untouched) |
| WD Re 1 | declared `machines/server.nix:637`, UUID `2735c646-9ffd-4d29-858c-f6990767b060`, **not connected** |
| WD Re 2 | declared `machines/server.nix:646`, UUID `221736bc-2a75-4949-823a-364c8c772dad`, **not connected** |
| `nvme0n1` | empty 3.6T WD Blue SN5100 — the Phase E migration target |
| `ls /mnt` | hangs — `/mnt/flex` is an absent-device `ntfs3` automount; read `/proc/mounts` instead |

### The existing WD Green restic repository

Path `/mnt/wd_green1/restic`, `root:root 0700`, created 2026-09-28 22:51 by
restic 0.19.0 with `--insecure-no-password` — its effective password is
**empty**. The journal shows a backup starting that night; completion is
**unproven**, and contents are unverified because reading them needs root.
Nothing was written to it by the Phase 0 investigation session.

### Backup source size (lower bound — some root-only paths were unreadable)

| Path | Bytes |
|---|---|
| `/home/andrew` | 94,439,153,664 |
| `/etc` | 688,128 |
| `/var/lib` | 20,609,769,472 |
| **Total** | **115,049,611,264** (~107.1 GiB) |

### Docker, measured 2026-10-02

| Type | Size |
|---|---|
| Images | 17.88 GB |
| Build cache | 36.37 GB (excluded from the backup; `overlay2` and `buildkit` are excluded, named volumes stay in) |
| Local volumes | 7 volumes, 582.1 MB total, including `mnemonix-hindsight-data` |

### PostgreSQL

Version 17.10, active, runs as OS user `postgres`, `PGDATA` is
`/var/lib/postgresql/17`, socket `/run/postgresql`. The default identity map
only maps `postgres postgres postgres` — **root is not mapped**, so the dump
must run as the `postgres` OS user (`runuser -u postgres`), never as root.

### SOPS and nix-secrets

- Exactly two recipients, both on this host: `&tower` (host SSH key) and
  `&author` (user SSH key). See blocker 3 above.
- `sops` is 3.13.3. `sops set --value-stdin` requires **JSON** on stdin, not
  raw plaintext — this was measured, not assumed.
- `nix-secrets` tag `v0.1.0` is lightweight and local-only, and names commit
  `58ae4ab1`, which a rollback left off trunk. `v0.1.0` must **not** be
  moved — it is a published fact, already consumed by `nix-meta/flake.lock`.
  Both the `nix-secrets` lane `phase-0-restic-password` and the `nix-meta`
  lane `phase-0-restic-backups` have since **landed and pushed**: `nix-secrets`
  trunk moved `b1983547` → `f1aba8e2`, and `nix-meta` trunk moved `1914dae` →
  `dddd4b19`. **`v0.1.1` now exists**: an annotated tag, tag object
  `3ecc2a60`, pointing at commit `f1aba8e2` (`nix-secrets` trunk tip),
  pushed to origin. `gitman release` still refuses to tag `nix-secrets` —
  it has no `pyproject.toml`, so `uv version --short` fails — so the user
  made the tag by hand with `git tag -a`, as a deliberate, one-step
  exception to the gitman-only rule; an agent cannot do this step, because
  the permission classifier refuses the same raw `git tag` mutation in this
  repository. `nix-meta` is now pinned to `v0.1.1`: `flake.nix` reads
  `?ref=refs/tags/v0.1.1`, and `flake.lock` locks `rev f1aba8e2`. The
  version-source gap is not open; it is filed against `gitman` at
  `~/Documents/Projects/gitman/.scratch/projects/63-non-python-repo-versioning/ISSUE.md`.
  The hand-tag exception must be re-granted by the user at every future
  `nix-secrets` release, until `gitman` closes that gap. Do not plan to
  duplicate the landing or the re-pin, which are already done.
- `nix-secrets` has no `publish.verify` and no `pyproject.toml`, so
  `gitman version` refuses there. Its verification is manual (`nix flake
  check --no-build` plus the functional tests recorded in `EVIDENCE.md` §4
  and §7).

### nix-meta verify gate

`gitman.toml:4` — `nix flake check --no-build` followed by
`nix eval --raw .#nixosConfigurations.server.config.system.build.toplevel.drvPath`.
Inside a Gitman workspace under `.worktrees/`, use the `path:$PWD` flake
form: the workspace is untracked in the outer git tree, and Nix's git
fetcher refuses it otherwise.

## Working rules

- Route all version control through `gitman`. Never run raw `git` or `jj`
  for a mutation. Run it from its own environment:
  `cd ~/Documents/Projects/gitman && devenv shell -- bash -c 'cd <repo> && gitman <verb>'`.
  For this session, only read-only verbs (`status`, `doctor`) are in scope.
- Never run `devenv` with `nix-meta` or `nix-secrets` as the working
  directory — it overwrites that repo's own `devenv.lock`.
- If any new work is later needed, it belongs in an isolated Gitman
  workspace — but this session proposes work, it does not start one.
- Write in Simplified Technical English: short sentences, active voice, one
  word per meaning, no filler.
- Never display or record secret material, password values, or
  private-key contents, even partially.
- No AI attribution in anything you write.
- End the session by proposing a dependency-ordered plan and a short list of
  decisions the plan needs from the user. Do not change the machine, a
  secret store, or any repository's history.
