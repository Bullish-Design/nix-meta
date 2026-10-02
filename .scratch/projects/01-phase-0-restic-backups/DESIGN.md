# Phase 0 design — restic system backups

Every claim about repository configuration carries a `file:line` anchor. Paths
are relative to the repository named in the heading.

---

## 1. Where the repository goes

**Decision.** The primary repository is `/mnt/wd_re1/restic`. The WD Caviar
Green keeps its existing repository as a secondary copy.

The WD Green is a 2009 `WDC WD20EADS-00R6B0`. Its last SMART reading showed
57,588 power-on hours and 2,175,705 load cycles with zero reallocated,
pending, or offline-uncorrectable sectors. The sector counts are clean, so the
disk is not failing. The hours and the load-cycle count say it is a poor sole
target for the only copy of this host.

Two WD Re `WD2000FYYZ` drives are already declared:

- `machines/server.nix:637` — `/mnt/wd_re1`, UUID
  `2735c646-9ffd-4d29-858c-f6990767b060`, ext4, `defaults nofail`
- `machines/server.nix:646` — `/mnt/wd_re2`, UUID
  `221736bc-2a75-4949-823a-364c8c772dad`, ext4, `defaults nofail`

Neither device is connected (see `EVIDENCE.md` §2). `nofail` means an absent
drive leaves a plain empty directory on the root filesystem. That is exactly
the failure the preflight check in §4 exists to catch.

**Order of preference.** WD Re 1 if it passes a long SMART test. WD Re 2 if
WD Re 1 fails and WD Re 2 passes. The WD Green is not acceptable as the sole
target.

`/mnt/shared` stays out of Phase 0. It is declared at
`machines/server.nix:620` as an `ntfs3` automount and holds 129 GiB of
unadjudicated data. Phase F stays blocked until that data has its own verified
policy. `profiles/backup.nix:510` asserts that the repository is not under
`/mnt/shared`.

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

`profiles/backup.nix:340` emits a loud warning when the profile is enabled and
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

**Decision.** Break the circle before the backup is relied on. Either is
enough; both is better:

1. Add a third recipient that is **not** on this host, then
   `secret-rotate --updatekeys`. Prove it decrypts:
   `SOPS_AGE_KEY_FILE=<off-host> sops -d secrets/secrets.yaml > /dev/null`.
2. Escrow the `restic-password` value in an off-host password manager.

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
| 3 | the repository directory exists and holds a `config` file | this profile never initializes a repository |
| 4 | the password file exists and is `root:root 400` | a different owner or mode means something else wrote it |
| 5 | the cache directory is on the backup disk | the module's default puts the cache on the root filesystem |

Condition 2 is implied by condition 1. It stays because a disagreement between
them means something is wrong, and because filling the root filesystem is the
worst outcome available.

Each refusal exits 1 before restic opens the repository. All five were tested;
see `EVIDENCE.md` §5.

`profiles/backup.nix:199` adds `RequiresMountsFor` for the mount point to every
unit, so systemd refuses to start them when the mount is not there.

Step 6 of the script is a plain `restic unlock`. Without `--remove-all` it
removes only a stale lock — one whose owning process is gone. An active lock
held by a concurrent operation survives, and the restic command that follows
fails loudly instead of racing it.

---

## 5. Never initialize automatically

**Decision.** `initialize = false` at `profiles/backup.nix:359`, permanently.

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
(`profiles/backup.nix:395` and `:586`), pointing at
`<mountPoint>/restic-cache`. `profiles/backup.nix:510` asserts the cache is
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
(`profiles/backup.nix:127`, `:158`, `:173`):

| Mechanism | Where |
|---|---|
| a marker file that survives reboots | `/var/lib/restic-backup-status/last-failure`, mode 0644 |
| a journal excerpt of the failed unit | `…/last-failure.log`, mode 0600, because it names paths under `/home` |
| a journal error | `logger -t restic-backup -p daemon.err` |
| live terminal sessions | `wall` |
| the next interactive login | `environment.interactiveShellInit`, `profiles/backup.nix:496` |
| a stalled schedule | `restic-backup-health`, daily, fails past 36 hours |

The marker is cleared only by a success (`profiles/backup.nix:158`). The
failure recorder is a templated unit reached by
`OnFailure=restic-backup-failure@%n.service`; it carries no `OnFailure` of its
own, so it cannot recurse.

A per-run alert cannot see a backup that stopped running at all. The health
timer is for that case, and it carries **no** `RequiresMountsFor`
(`profiles/backup.nix:441`) so it still runs and still fails when the disk is
gone.

### Explicit failure behaviour

| Situation | Behaviour |
|---|---|
| the disk is missing | `RequiresMountsFor` and preflight condition 1 fail the unit; no repository and no cache are created on the root filesystem |
| the disk is full | restic exits non-zero; the marker records it. No snapshot is deleted as an emergency response, and the failure evidence is preserved |
| a stale repository lock | `restic unlock` clears it |
| an active repository lock | it survives; the restic command fails loudly |

---

## 9. What the backup does not prove

**PostgreSQL.** A live cluster lives at `/var/lib/postgresql/17`
(`machines/server.nix:318`, pinned to `postgresql_17`). Atuin uses it.
Copying live cluster files is **not** a valid database backup.

`profiles/backup.nix:550` adds a logical `pg_dumpall` stream into the same
repository, behind `nix-meta.backup.postgres.enable`, default off. The owner
question is settled: the generated `pg_hba.conf` carries
`local all postgres peer map=postgres` and the default `identMap` maps only
`postgres postgres postgres`
(`nixpkgs/nixos/modules/services/databases/postgresql.nix:692` and `:701`).
root is **not** mapped, so root cannot connect as the `postgres` role.
`runuser -u postgres` drops to that user for the dump while restic keeps
running as root to write the repository.

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
are excluded (`profiles/backup.nix:255`). Images are rebuildable from their
sources; the build cache alone was 36.37 GB. Named volumes stay in.

---

## 10. The nix-secrets release that was rewound

Found during this work, and it changes how `nix-secrets` must be released.

`nix-meta/flake.nix:77` pins
`git+file:///home/andrew/Documents/Projects/nix-secrets?ref=refs/tags/v0.1.0`,
locked to `58ae4ab1`. That commit is **not on `nix-secrets` trunk**:

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
