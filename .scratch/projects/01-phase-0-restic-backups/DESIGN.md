# Phase 0 design — restic system backups

Every claim about repository configuration carries a `file:line` anchor. Paths
are relative to the repository named in the heading.

---

## 1. Where the repository goes

**Decision.** The primary repository is `/mnt/wd_green1/restic`. It already
exists: created 2026-09-28 by restic 0.19.0, root-owned, mode 0700. This is
the user's decision. Their reasoning: a backup on an aged disk beats the
nothing that exists today. A NAS will come later and give a second location
to save to.

The WD Green is a 2009 `WDC WD20EADS-00R6B0`. Its last SMART reading showed
57,588 power-on hours and 2,175,705 load cycles with zero reallocated,
pending, or offline-uncorrectable sectors. The sector counts are clean, so the
disk is not failing. The hours and the load-cycle count are the cost of this
decision, not an open objection. They are an **accepted risk**: the user
chose to start backing up now, on the disk that is actually connected and
already holds a repository, rather than wait for a WD Re disk to be fitted
and proved.

Two WD Re `WD2000FYYZ` drives are already declared:

- `machines/server.nix:637` — `/mnt/wd_re1`, UUID
  `2735c646-9ffd-4d29-858c-f6990767b060`, ext4, `defaults nofail`
- `machines/server.nix:646` — `/mnt/wd_re2`, UUID
  `221736bc-2a75-4949-823a-364c8c772dad`, ext4, `defaults nofail`

Neither device is connected (see `EVIDENCE.md` §2). Both stay declared and
both stay the **preferred upgrade path**: a WD Re disk, once connected and
passing a long SMART test, should replace the WD Green as the primary
target. `nofail` means an absent drive leaves a plain empty directory on the
root filesystem. That is exactly the failure the preflight check in §4 exists
to catch.

**The planned NAS.** A NAS is planned as the **second copy location** — not
as a replacement for the primary disk. It solves single-disk risk: with a
second copy, no single drive failure loses the only backup.

**The point the NAS does not solve, stated plainly.** A second copy removes
single-disk risk. It does not remove the key-recovery circularity described
in §3. Both copies would still be encrypted to `restic-password`, and that
secret is encrypted only to two keys that live on the host the backup
protects. Losing the host locks both copies — the NAS copy included. Off-host
escrow or a third SOPS recipient (§3) is still required before the backup can
be relied on for host loss. Adding a NAS does not change this; only §3's
decision does.

`/mnt/shared` stays out of Phase 0. It is declared at
`machines/server.nix:620` as an `ntfs3` automount and holds 129 GiB of
unadjudicated data. Phase F stays blocked until that data has its own verified
policy. `profiles/backup.nix:614` asserts that the repository is not under
`/mnt/shared`.

The profile is enabled on the host: `machines/server.nix:668` sets
`nix-meta.backup.enable = true` with `mountPoint = "/mnt/wd_green1"`, matching
the decision above.

### No repository initialization is needed

The repository at `/mnt/wd_green1/restic` already exists. There is nothing to
initialize. `profiles/backup.nix:415` sets `initialize = false`, and that
setting stays permanent — it was never conditional on which disk is primary.

The path to a working backup from here is three steps, in order:

1. Adjudicate the existing repository **read-only** — confirm it opens and
   list its snapshots, without writing to it.
2. Replace the repository's current empty password (`--insecure-no-password`)
   with a real one, using restic's add/verify/remove key sequence.
3. Activate the profile by giving `restic-password` encrypted material in
   `nix-secrets` (§2).

---

## 2. Where the secret comes from

**Decision.** `restic-password`, delivered by sops-nix to
`/run/secrets/restic-password` as `root:root 0400`. The profile reads the
path, never the value.

`nix-secrets` is the naming authority. The name is declared at
`nix-secrets/modules/secrets.nix:49`, inside the `canonicalNames` list that
starts at `:39`.

`nix-secrets` filters active names that have no encrypted material:

- `nix-secrets/modules/secrets.nix:121` — `availableKeys`, read from the
  cleartext key names in `secrets.yaml`
- `:128` — `missingKeys`
- `:133` — `effectiveNames`, which drops a missing key with a warning

So `config.sops.secrets."restic-password"` can be **absent at evaluation
time**. Reading `.path` on an absent secret is an evaluation error, not a
warning. `profiles/secrets.nix:10` already solves this for
`deepseek-api-key`, and `profiles/backup.nix:45` uses the same guard:

```nix
hasPassword = config.sops.secrets ? "restic-password";
active = cfg.enable && hasPassword;
```

`profiles/backup.nix:394` emits a loud warning when the profile is enabled and
the secret has not arrived. A silently inert backup profile is the failure this
phase exists to prevent.

The host's active list is `profiles/secrets.nix:27`. It does **not** yet name
`restic-password`, so nothing on the host reads it.

---

## 3. The recovery circle, and how to break it

The age identity IS the host SSH key — `nix-secrets/modules/secrets.nix:156`
defaults `ageKeySource` to `/etc/ssh/ssh_host_ed25519_key`.

The store has two recipients, and **both live on this one host**:

- `nix-secrets/secrets/.sops.yaml:30` — `&tower`, derived from
  `/etc/ssh/ssh_host_ed25519_key`
- `nix-secrets/secrets/.sops.yaml:35` — `&author`, derived from
  `~/.ssh/id_ed25519`

That is a circle. The backup needs the restic password. The password is
encrypted to keys that only exist on the host the backup protects. Lose the
host and the backup cannot be opened.

**The structural fact about restic keys.** A restic repository has exactly
one master key. Every entry under `keys/` wraps that same master key under a
per-key scrypt-derived key. `internal/repository/key.go`'s `AddKey()` copies
the existing master key when `key add` runs; it cannot mint a new one. So any
key grants bit-identical access to the same plaintext, whatever its own
password strength. A repository is only as strong as its weakest key. This is
the repository format, not a setting.

**The KDF, measured on this host.** restic derives each key with scrypt, from
`github.com/elithrar/simple-scrypt`, via `internal/crypto/kdf.go`.
`internal/repository/key.go` sets `KDFTimeout = 500ms` and `KDFMemory = 60`
MiB, and recalibrates on every `key add`. On this host (a Xeon W-2125),
`key add` wrote `N=32768, r=8, p=6` into the key file — about 32 MiB per
guess. The calibration targets wall-clock time on the machine that ran
`key add`, not a security margin, so the parameters are chosen to feel
instant to the operator. An attacker pays the recorded `N/r/p` forever: the
parameters sit in the key file in cleartext, by necessity.

**Restic enforces no password strength.** A key with password `1234` was
accepted with exit 0 and no warning. An empty password is possible with
`--new-insecure-no-password`. The strength of a human-held key is entirely
the human's responsibility.

**Required passphrase strength, with the reasoning.** Cost-per-guess is fixed
once the key is written, so keyspace is the only lever left. The EFF long
wordlist has 7776 words, about 12.925 bits per word: 6 words ≈ 77.5 bits,
7 ≈ 90.5 bits, 8 ≈ 103.4 bits. Even at a deliberately pessimistic 10^9
guesses per second — far beyond what 32 MiB memory-hard scrypt realistically
allows — a 7-word phrase needs about 1.3×10^18 seconds to exhaust. That
attacker-throughput figure is an order-of-magnitude assumption, not a
measurement; no GPU benchmark was run. **Recommend 7 words. Never fewer than
6. Generate the phrase by dice or a tool. Never invent it by hand.**

**The three options, compared.**

| Option | What it stores | What can leak | Survives host loss | Ongoing maintenance | Adds a new restic credential? |
|---|---|---|---|---|---|
| 1. A second restic key, passphrase held by a human | Nothing — the phrase lives only in a person's memory | The phrase, if coerced or guessed | Yes | None | **Yes** — per the structural fact above, it is a new, independently-crackable key |
| 2. Escrow the random password in an off-host password manager | The exact generated secret, in a third-party vault | That vendor account, or a vendor breach | Yes | Renew vault access over time | No — it is the same credential, not a new one |
| 3. A third age recipient on separate hardware | An age keypair, private half off-host | Loss or clone of that device | Yes | Update `.sops.yaml` and run `updatekeys` on change; the device must stay reachable for years | No — it operates at the SOPS layer and never touches restic's key list |

Option 1 is the only one that adds a new attackable credential to the restic
repository. It also has no redundancy: the phrase lives only in one person's
memory, so forgetting it, or that person being unavailable, permanently
loses that path. Severity is **high** if it is the sole recovery mechanism.
Treat it as a supplementary path only, never as the only one.

**Recommendation.** Combine options 2 and 3; together they are the real
recovery path. Prove option 3 decrypts, with the real path to the off-host
identity in place of the placeholder:

```bash
SOPS_AGE_KEY_FILE=/path/to/off-host-identity \
  sops -d secrets/secrets.yaml > /dev/null
```

Option 1 is optional convenience on top of options 2 and 3. If adopted, it is
a second, parallel unlock path, not a backup of the first.

An earlier draft of this design called option 1 the cleanest fix, on the
grounds that it has "nothing to leak." That was wrong on both counts: the
structural fact above means option 1's key is exactly as strong, and exactly
as weak, as every other key in the repository, and a memory-only passphrase
is itself a single point of failure.

No off-host recipient exists today and none was invented. This is recorded as
blocker B3 in `IMPLEMENTATION.md`. `nix-secrets/RUNBOOK.md` §3a states the
same constraint for the next reader.

**Phase E consequence.** A fresh install generates a NEW host key, and sops-nix
then cannot decrypt anything. `/etc/ssh/ssh_host_ed25519_key` must be restored
before the first activation on the replacement system. The restore gate in §7
therefore includes that exact file. Its contents are never displayed or
recorded.

---

## 4. The preflight check

**Decision.** No restic command runs until five conditions hold. The script is
`profiles/backup.nix:68`, shared by the backup unit (as
`backupPrepareCommand`, which lands first in `preStart`) and by the check unit
(as `ExecStartPre`).

| # | Condition | Why |
|---|---|---|
| 1 | the mount point is a real mount point | `nofail` leaves an empty directory when the disk is absent |
| 2 | the mount is not the root filesystem | the root filesystem is 95% full |
| 3a | the repository directory exists | this profile never initializes a repository |
| 3b | the repository directory holds a `config` file | a directory with no `config` is not a repository at all |
| 4 | the password file exists and is `root:root 400` | a different owner or mode means something else wrote it |
| 5 | the cache directory is on the backup disk | the module's default puts the cache on the root filesystem |

Condition 2 is implied by condition 1. It stays because a disagreement between
them means something is wrong, and because filling the root filesystem is the
worst outcome available.

Each refusal exits 1 before restic opens the repository. All six were tested;
see `EVIDENCE.md` §5.

### Classifying a missing repository (3a and 3b)

Conditions 3a and 3b are not merely two more `fail` calls. Each writes a
distinct marker before failing, at `profiles/backup.nix:87` (the
`write_needs_init` helper) and `:134`-`:141` (the two call sites):

| Sub-case | `needs-init` `status` field | Why reported differently |
|---|---|---|
| 3a: the directory is absent | `directory-missing` | the ordinary case — nobody has initialized a repository here yet |
| 3b: the directory exists, no `config` | `config-missing` | more alarming — something other than restic created this directory, so it is not an ordinary uninitialized repository |

The marker (`/var/lib/restic-backup-status/needs-init`, written by
`write_needs_init`) carries the repository path, the mount point, the
timestamp, the sub-case, and the exact operator command to run — the same
`restic init` invocation form used in `IMPLEMENTATION.md` steps C1b/C6
(`nix build` to resolve the `restic` binary, then `--repo`/`--password-file`),
quoted so it is safe to paste into zsh. It is cleared only on success,
alongside `last-failure` (`profiles/backup.nix:219`).

**Condition 1 (and 2) never write this marker.** `write_needs_init` is called
only from the 3a/3b branches. A missing disk is not a missing repository:
telling the operator to run `restic init` against an unmounted path is the
exact failure `initialize = false` exists to prevent. This boundary was
tested directly; see `EVIDENCE.md` §5.

`profiles/backup.nix:251` adds `RequiresMountsFor` for the mount point to every
unit, so systemd refuses to start them when the mount is not there.

Step 6 of the script is a plain `restic unlock`. Without `--remove-all` it
removes only a stale lock — one whose owning process is gone. An active lock
held by a concurrent operation survives, and the restic command that follows
fails loudly instead of racing it.

### The activation-time warning

Waiting for the preflight check to run means the operator learns about a
missing repository only when the timer fires — up to a day late. A second,
independent check runs at every `nixos-rebuild switch`, via
`system.activationScripts.resticBackupNeedsInitWarning`
(`profiles/backup.nix:583`). It re-checks the same directory/`config`
condition and prints the same operator command, but to stderr during
activation rather than to a marker file.

**It warns; it never fails.** The script ends with an unconditional `exit 0`,
regardless of what it found. This is a deliberate departure from
`nix-secrets/modules/secrets.nix`'s `nixSecretsValidateAgeKey`, which exits 1
when the age identity is absent — correct there, because an absent age key
makes *every* secret on the host undecryptable. A missing restic repository
blocks only this one backup profile. Refusing to activate the whole system
over a backup disk that is not ready yet would hold unrelated work hostage,
and this profile is not important enough to justify that trade. The script is
gated by the same `active` condition (`cfg.enable && hasPassword`) that gates
every unit in this profile — it does not exist in `config.system.activationScripts`
at all when the profile is inactive.

---

## 5. Never initialize automatically

**Decision.** `initialize = false` at `profiles/backup.nix:415`, permanently.

The NixOS restic module's `initialize = true` path runs
`restic cat config || restic init` in `preStart`
(`nixpkgs/nixos/modules/services/backup/restic.nix:481`). Against an absent
mount that writes a fresh, empty repository onto the root filesystem and
reports success. An empty repository that reports success is worse than any
failure.

Initialization is an operator step, run once, against a mount that has been
proved. `IMPLEMENTATION.md` step C1 holds the command.

---

## 6. The cache does not go on the root filesystem

The module hardcodes `RESTIC_CACHE_DIR = "/var/cache/restic-backups-<name>"`
(`nixpkgs/nixos/modules/services/backup/restic.nix:426`). The root filesystem
has 26 GB free of 444 GB.

**Decision.** Override it per unit with `lib.mkForce`
(`profiles/backup.nix:451` and `:688`), pointing at
`<mountPoint>/restic-cache`. `profiles/backup.nix:629` asserts the cache is
under the mount point.

The module's `CacheDirectory=` still creates an empty
`/var/cache/restic-backups-system`. It stays empty and costs nothing.

The generated `restic-system` wrapper reads the backup unit's environment, so a
manual operator command picks up the same repository, password file, and cache.
That is why no separate global `restic` package is added: a bare `restic` with
no `RESTIC_*` set is how an operator reaches the wrong repository.

---

## 7. The restore gate

**Decision.** A snapshot does not complete Phase 0. A verified restore does.

Three exact files, chosen because each one proves a different thing:

| File | Proves |
|---|---|
| `/home/andrew/Documents/Projects/nix-meta/AGENTS.md` | ordinary user content survives |
| `/etc/ssh/ssh_host_ed25519_key` | the Phase E key is in the backup, with `root:root 0600` |
| `/var/lib/nixos/declarative-users` | root-only system state survives |

Each restored file must exist, be non-empty, and match the live file with
`cmp --silent`. A directory listing does not pass. The command block is
`IMPLEMENTATION.md` step C5.

The gate proves **file restoration**. It does not prove application
consistency. See §9.

---

## 8. Failure is never silent

There is no proven remote notification channel on this host, and none was
claimed. The signal is local and persistent
(`profiles/backup.nix:171`, `:210`, `:225`):

| Mechanism | Where |
|---|---|
| a marker file that survives reboots | `/var/lib/restic-backup-status/last-failure`, mode 0644 |
| a needs-init marker, when the repository itself is missing | `/var/lib/restic-backup-status/needs-init`, mode 0644 — see "Classifying a missing repository" below |
| a journal excerpt of the failed unit | `…/last-failure.log`, mode 0600, because it names paths under `/home` |
| a journal error | `logger -t restic-backup -p daemon.err`, folding in the needs-init guidance when that marker is present |
| live terminal sessions | `wall`, likewise folding in the needs-init guidance |
| the next interactive login | `environment.interactiveShellInit`, `profiles/backup.nix:553`, prints both markers when present |
| `nixos-rebuild switch` activation | `system.activationScripts.resticBackupNeedsInitWarning`, `profiles/backup.nix:583` — see §4 |
| a stalled schedule | `restic-backup-health`, daily, fails past 36 hours |

The marker is cleared only by a success (`profiles/backup.nix:210`), which
also clears `needs-init`. The failure recorder is a templated unit reached by
`OnFailure=restic-backup-failure@%n.service`; it carries no `OnFailure` of its
own, so it cannot recurse.

### Classifying a missing repository

A missing or invalid repository (preflight conditions 3a/3b, §4) is no longer
indistinguishable from any other failure. `write_needs_init`
(`profiles/backup.nix:87`) records the repository path, the mount point, the
timestamp, the sub-case (`directory-missing` or `config-missing`), and the
exact `restic init` command to run — quoted for zsh — before the unit fails.
`restic-backup-failure` (`profiles/backup.nix:171`) then folds that guidance
into both the journal error and the `wall` message, and the login hook
(above) prints the marker's contents directly. The activation-time warning in
§4 reaches the same information through an independent path, at
`nixos-rebuild switch` time rather than waiting for a failed unit.

A per-run alert cannot see a backup that stopped running at all. The health
timer is for that case, and it carries **no** `RequiresMountsFor`
(`profiles/backup.nix:499`) so it still runs and still fails when the disk is
gone.

### Explicit failure behaviour

| Situation | Behaviour |
|---|---|
| the disk is missing | `RequiresMountsFor` and preflight condition 1 fail the unit; no repository and no cache are created on the root filesystem; **no** `needs-init` marker is written |
| the disk is mounted but the repository is missing or invalid | preflight condition 3a/3b fails the unit and writes `needs-init` with the exact operator command; `nixos-rebuild switch` warns about the same condition independently (§4) |
| the disk is full | restic exits non-zero; the marker records it. No snapshot is deleted as an emergency response, and the failure evidence is preserved |
| a stale repository lock | `restic unlock` clears it |
| an active repository lock | it survives; the restic command fails loudly |

---

## 9. What the backup does not prove

**PostgreSQL.** A live cluster lives at `/var/lib/postgresql/17`
(`machines/server.nix:320`, pinned to `postgresql_17`). Atuin uses it.
Copying live cluster files is **not** a valid database backup.

`profiles/backup.nix:652` adds a logical `pg_dumpall` stream into the same
repository, behind `nix-meta.backup.postgres.enable`, default off. The owner
question is settled: the generated `pg_hba.conf` carries
`local all postgres peer map=postgres` and the default `identMap` maps only
`postgres postgres postgres`
(`nixpkgs/nixos/modules/services/databases/postgresql.nix:688` and `:699`).
root is **not** mapped, so root cannot connect as the `postgres` role.
`runuser -u postgres` drops to that user for the dump while restic keeps
running as root to write the repository. These two anchors point into
nixpkgs, an external pinned dependency, so they move whenever the nixpkgs
pin moves — unlike the in-repo anchors in this document, which move only
when this repository's own files change.

The job is **unproven**: it has never been run, because running it needs root.
Until an operator runs it and confirms the snapshot, `/var/lib/postgresql`
stays **inside** the file backup. Do not exclude it before then. The file copy
is not a valid backup, but it is not nothing either, and removing it before the
replacement is proved would leave the database with no coverage at all.

**Mnemonix Hindsight.** The Docker volume `mnemonix-hindsight-data` is under
`/var/lib/docker/volumes`, which the backup includes. A file-level restore of a
running container's volume does not prove application consistency. This has no
solution yet and must be settled before Phase E.

**Docker layers.** `/var/lib/docker/overlay2` and `/var/lib/docker/buildkit`
are excluded (`profiles/backup.nix:324`). Images are rebuildable from their
sources; the build cache alone was 36.37 GB. Named volumes stay in.

---

## 10. The nix-secrets release that was rewound

Found during this work, and it changes how `nix-secrets` must be released.
**This section describes the state as found, before the re-pin.** Line 77
now reads `v0.1.1`, not `v0.1.0` — the resolution is recorded in §12 below.

At the time this was found, `nix-meta/flake.nix:77` pinned
`git+file:///home/andrew/Documents/Projects/nix-secrets?ref=refs/tags/v0.1.0`,
locked to `58ae4ab1`. That commit was **not on `nix-secrets` trunk**:

| Ref | Commit |
|---|---|
| `v0.1.0` tag | `58ae4ab1` "feat: provision deepseek-api-key; fix on-box sops authoring" |
| `nix-secrets` trunk and `origin/main` | `b1983547`, the parent of `58ae4ab1` |

A rollback rewound jj's record of trunk after the release, leaving `58ae4ab1`
reachable only through its tag and its content back on the
`phase-0-restic-password` draft lane. `gitman repair` re-pointed the colocated
git ref to jj, which matched `origin/main`. Nothing was lost — the tag holds
the commit and the lane holds the content.

**Consequence.** `nix-meta` already consumes the `restic-password`
declaration, through `v0.1.0`. Only the encrypted material is missing.

**Decision.** Land the lane once, then release **`v0.1.1`** on trunk and bump
`nix-meta` to it. Do not try to move `v0.1.0`: a tag that has been consumed by
a lock file is a published fact. `v0.1.0` stays as a historical tag whose
commit is not an ancestor of trunk.

The lane has since landed and pushed. The release has not: `gitman release`
has no version source to read in `nix-secrets`. See §12.

---

## 11. Schedule

| Unit | When | Why |
|---|---|---|
| `restic-backups-system` | daily `02:30`, `Persistent`, `RandomizedDelaySec=20m` | the host shares 4 cores with Dagu, inferference-router, SilverBullet, Atuin and argentic; spread the start |
| `restic-backups-postgres` | daily `02:00`, `Persistent`, `RandomizedDelaySec=10m` | before the file snapshot, so the dump is never the newer of the two |
| `restic-check-system` | weekly `Sun 04:00`, `--read-data-subset=10%` | a structural check alone does not detect bit rot, and the fallback disk is old |
| `restic-backup-health` | daily `09:00` | catches a schedule that stopped; daily, not hourly, so `wall` does not spam |

Retention: `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`, run as
`forget --prune` inside the backup unit.

`TimeoutStartSec=infinity`, `IOSchedulingClass=idle` and `Nice=10` on the
backup and check units: the first run copies about 107 GiB to a 5400 rpm disk
while the host keeps serving.

---

## 12. Tagging nix-secrets

`gitman release` cannot tag `nix-secrets`. It refuses:

```
Gitman release — REFUSED
reason: uv version --short failed: error: No `pyproject.toml` found in current directory or any parent directory
```

`gitman/src/gitman/init.py:49`: "no pyproject.toml version — version/release
need a uv project". `gitman release --version 0.1.1` refuses the same way, so
an explicit version does not bypass the `uv` read. This is by design.

Three options. Each is described below with its trade-off. None is
recommended over the others; the choice is the user's, because it sets a
fleet-wide convention (see `IMPLEMENTATION.md` §B4).

**Option 1 — add a minimal `pyproject.toml` and `uv.lock` to `nix-secrets`.**
`gitman release` then works, and all version control stays inside `gitman`.
`nix-secrets/devenv.nix` already configures `languages.python` with a
uv-managed venv, so the files are not foreign to the repository. The cost:
a Python project file in a repository that ships only Nix modules and shell
scripts. The same question then applies to `nix-meta`, `nixos-core`,
`nix-terminal` and `nixbuild`, none of which has a `pyproject.toml` either.

**Option 2 — tag by hand with raw `git tag -a`, once per release.** This
matches what `nix-nvim` and `nix-paseo` already do. The cost: it breaks the
standing rule that all version control goes through `gitman`, and a
hand-made tag is not gated by `publish.verify`.

**Option 3 — pin by `rev` instead of by tag.** Change the `nix-meta` input to
`git+file:///home/andrew/Documents/Projects/nix-secrets?rev=<commit>`. A rev
is immutable, so it gives a stronger guarantee than a tag, which can be
moved. It needs no tag and no raw `git`. The cost: it departs from the
`?ref=refs/tags/vN` convention that Phase B plans to use for every depot
input, and a rev carries no human-readable version.

Option 3 is the only one that needs neither a new file nor a rule exception.

**Outcome.** The user chose a hand-made annotated tag (Option 2), as a
deliberate, one-step exception to the gitman-only rule. An agent cannot
perform this step: the permission classifier refused the same `git tag`
command with `Reason: [Auto-Mode Bypass]`, because the gitman-only rule lives
in this repository's own `AGENTS.md`. The user ran `git tag -a` by hand
instead.

`nix-secrets` now carries tag `v0.1.1`: annotated tag object `3ecc2a60`,
pointing at commit `f1aba8e2`, which is `nix-secrets` trunk tip. The tag is
pushed to origin. `v0.1.0` is untouched, still lightweight, still at
`58ae4ab1`, still not an ancestor of trunk.

This gap is filed against `gitman`, not left open, at
`~/Documents/Projects/gitman/.scratch/projects/63-non-python-repo-versioning/ISSUE.md`.
Until `gitman` can tag a repository with no uv project, the hand-tag
exception must be re-granted by the user at every `nix-secrets` release.
