# Phase 0 evidence

No secret value, password, or private-key content appears in this document.

**Host:** `server` · **Kernel:** 6.18.38 · **NixOS:** 26.11.20260705.d407951 (Zokor)
**Current system generation:** 131 (`/nix/var/nix/profiles/system-131-link`,
activated 2026-10-01 13:21)
**Session:** 2026-10-01 23:00 EDT to 2026-10-02 01:30 EDT
**Tools:** gitman 0.10.3 · pyjutsu 0.22.0 (jj-lib 0.44.0) · sops 3.13.3 ·
restic 0.19.0

---

## 1. Gate status

| Gate condition | State |
|---|---|
| `restic snapshots` lists a successful snapshot | **NOT MET** — no repository on a healthy disk |
| a repository check succeeds | **NOT MET** |
| the restore gate restores three exact files and `cmp` matches | **NOT MET** |
| `EVIDENCE.md` records the result | partial — this document records the work done |
| the repository changes have landed and been pushed | **MET** — both lanes landed and pushed to origin; the `nix-secrets` tag and the `nix-meta` re-pin are still outstanding (see §8) |

**Phase 0 is not complete.** Three operator actions block it; see
`IMPLEMENTATION.md` §B.

---

## 2. Storage, measured 2026-10-02

`lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL`:

```
sda           1.8T disk                                 WDC WD20EADS-00R6B0
└─sda1        1.8T part ext4   wd_green1 /mnt/wd_green1
sdb           1.9T disk                                 TEAM TM8PS7002T
├─sdb1         16M part
└─sdb2        1.9T part ntfs   SHARED    /mnt/shared
zram0        62.7G disk swap   zram0     [SWAP]
nvme0n1       3.6T disk                                 WD Blue SN5100 4TB
nvme1n1     476.9G disk                                 NX-512 2280
├─nvme1n1p1     1G part vfat   NIXBOOT   /boot
├─nvme1n1p2    32G part swap   NIXSWAP   [SWAP]
└─nvme1n1p3 443.9G part btrfs  NIXROOT   /home
```

| Filesystem | Mount | Size | Used | Avail | Use% |
|---|---|---|---|---|---|
| `/dev/nvme1n1p3` (btrfs `NIXROOT`) | `/` and `/home` | 444G | 416G | 26G | **95%** |
| `/dev/sda1` (ext4 `wd_green1`) | `/mnt/wd_green1` | 1.8T | 59G | 1.7T | 4% |
| `/dev/sdb2` (ntfs3 `SHARED`) | `/mnt/shared` | 1.9T | 130G | 1.8T | 7% |

**No WD Re device is present.** This is the definitive finding behind blocker
B1. The two declared UUIDs resolve to nothing:

- `machines/server.nix:637` — `/mnt/wd_re1`, `2735c646-9ffd-4d29-858c-f6990767b060`
- `machines/server.nix:646` — `/mnt/wd_re2`, `221736bc-2a75-4949-823a-364c8c772dad`

`/proc/mounts` confirms which `/mnt` paths are real:

```
systemd-1 /mnt/flex       autofs   (waiting, device absent)
/dev/sdb2 /mnt/shared     ntfs3
/dev/sda1 /mnt/wd_green1  ext4
```

`nvme0n1` is the empty Phase E target. Out of scope.

**Note on `ls /mnt`.** It hangs. `/mnt/flex` is an `ntfs3` automount
(`machines/server.nix:606`) whose device is absent, so a `stat` on the path
blocks on an automount attempt. Read `/proc/mounts` instead.

---

## 3. The existing WD Green restic repository

```
$ stat -c '%n %U:%G %a' /mnt/wd_green1/restic
/mnt/wd_green1/restic root:root 700

$ ls -la /mnt/wd_green1/
drwx------ root  lost+found
drwx------ root  restic        (created 2026-09-28 22:51)

$ du -sh /mnt/wd_green1/restic
du: cannot read directory '/mnt/wd_green1/restic': Permission denied
```

The repository is unreadable without root, so its contents are **unverified**.
Indirect evidence that it holds real data: the filesystem reports 59 GB used,
`lost+found` is empty, and nothing else is on the disk.

Journal entries, confirmed against the live journal:

```
Sep 28 20:19:11  sudo: andrew : ... SOPS_AGE_SSH_PRIVATE_KEY_FILE=/etc/ssh/ssh_host_ed25519_key
                 ./scripts/secret-add restic-password
Sep 28 22:51:13  sudo: COMMAND=.../restic-0.19.0/bin/restic
                 --repo /mnt/wd_green1/restic --insecure-no-password init
Sep 28 22:51:16  sudo: COMMAND=.../restic-0.19.0/bin/restic
                 --repo /mnt/wd_green1/restic --insecure-no-password backup
                 --exclude /home/andrew/.cache --exclude **/.devenv
                 --exclude **/target --exclude **/.venv --exclude **/node_modules
                 --exclude **/.worktrees /home/andrew /etc /var/lib
```

Three facts follow.

1. The repository's effective password is **empty**. It was initialized with
   `--insecure-no-password`.
2. The 2026-09-28 backup **started**. The journal records the `sudo`
   invocation, not restic's own output, which went to a terminal. Completion
   remains **unproven**. `IMPLEMENTATION.md` step C1 is the read-only
   adjudication.
3. The 2026-09-28 attempt to add `restic-password` **failed**. It used
   `SOPS_AGE_SSH_PRIVATE_KEY_FILE`, which offers the SSH key as an
   `ssh-ed25519` age identity. Both recipients in `.sops.yaml` are native
   `age1…` X25519 stanzas, so no identity matched. `nix-secrets/devenv.nix`
   now exports `SOPS_AGE_KEY_CMD` with `ssh-to-age -private-key`, which
   converts the key to the right identity type. That fix is on the
   `phase-0-restic-password` lane.

No write of any kind was made to this repository during this session.

**WD Green SMART, previous reading (not re-measured — `smartctl` needs root):**

| Field | Value |
|---|---|
| Model | `WDC WD20EADS-00R6B0` |
| Power-on hours | 57,588 |
| Load cycles | 2,175,705 |
| Reallocated sectors | 0 |
| Current pending sectors | 0 |
| Offline uncorrectable | 0 |
| SMART status | not failing |
| Last self-test | success |
| Temperature | 35 °C |

---

## 4. sops stdin behaviour — measured, not assumed

`sops` 3.13.3 `set --value-stdin` exists. Its input format was measured on a
throwaway store with a throwaway age key in `/tmp`:

| Input on stdin | Result |
|---|---|
| raw plaintext `line1\nline2-with-"quote"\n` | **rejected**: `Value for --set is not valid JSON`; nothing written |
| JSON-encoded `"json\nvalue"` | accepted; decrypts back to the exact two lines |

So the JSON-encoding step stays. `scripts/secret-add` now pipes
`python3 -c json.dumps` into `sops set --value-stdin`, which keeps the value
out of both processes' arguments.

### `secret-add` functional test

Run against a throwaway store in `/tmp` with a throwaway age key:

| Case | Result |
|---|---|
| multi-line value with a tab and embedded quotes | set; round-trip is byte-exact (`cat -A` verified `├──┤` for the tab) |
| 32 random bytes, base64, piped in (the `restic-password` shape) | set; decrypts to 44 bytes. The value was never printed |
| empty stdin | refused, **exit 1**, store unchanged — the key was not written |
| a value given as an argument | refused, **exit 2**, with the reason |
| an invalid name `Bad_Name` | refused, **exit 1** |
| stdin is a terminal | refused, exit 2 |

Exit codes follow the standing contract: `0` ok, `1` finding, `2` usage.

### `secret-ls` cross-check

The script's `canonical` array and `modules/secrets.nix` `canonicalNames` were
compared programmatically. Both now hold the same ten names, in the same order:

```
tailscale-auth-key attic-signing-key attic-push-token nix-builder-ssh-key
github-deploy-key github-pat hf-token deepseek-api-key
subconscious-api-key restic-password
```

### SOPS recipients — the actual set

```
nix-secrets/secrets/.sops.yaml:30   &tower   age1xkwrt8…q0zrddu   /etc/ssh/ssh_host_ed25519_key
nix-secrets/secrets/.sops.yaml:35   &author  age1f6hjsh…mtq03l    ~/.ssh/id_ed25519
```

Both recipients are present in `secrets.yaml`'s own metadata, so the file
really is encrypted to exactly these two. Both live on this host.

**There is no off-host recipient, and none was created.** Off-host recovery is
therefore **unproven** and cannot be proven from this session. Blocker B3.

The store currently holds three keys: `tailscale-auth-key`,
`subconscious-api-key`, `deepseek-api-key`. `restic-password` has **no
material**.

---

## 5. The preflight check — all five refusals tested

The generated script was copied out of the Nix store, its paths redirected to a
temporary tree, and each condition driven to failure. `restic` was stubbed so
no repository could be touched.

| # | Condition driven to failure | Output | Exit |
|---|---|---|---|
| 1 | the mount point is a plain directory on the root filesystem | `/…/mnt is not a mount point. The backup disk is absent.` | 1 |
| 3 | the mount is real, the repository is absent | `/mnt/wd_green1/NOPE-repo does not exist. Initialize it as an operator step.` | 1 |
| 4 | the repository is present, the password file is absent | `/…/pw is absent. sops did not decrypt restic-password.` | 1 |
| 4b | the password file is `andrew:users 644` | `/…/pw is andrew:users 644; expected root:root 400.` | 1 |
| 4c | the password file is `andrew:users 400` | `/…/pw is andrew:users 400; expected root:root 400.` | 1 |

Every refusal happened **before** the stubbed restic was reached. Condition 2
(the mount is the root filesystem) is unreachable while condition 1 holds, by
design; condition 5 (the cache is off the backup disk) sits behind condition 4
and was not reachable in the harness.

### The failure and success scripts

Driven directly, with the status directory redirected to a temporary path:

| Case | Output | Exit |
|---|---|---|
| health check, no marker at all | `no successful backup has ever been recorded.` | 1 |
| health check, marker written 0 s ago | `last successful backup 0 s ago.` | 0 |
| health check, marker 40 h old (144000 s > 129600 s) | `the last successful backup is 144000 s old; the limit is 129600 s.` | 1 |
| health check, `epoch=notanumber` | `… is unreadable.` | 1 |
| a success clears an existing failure marker | both `last-failure` and `last-failure.log` removed | 0 |
| a success with no `<kind>` argument | `usage: restic-backup-success <backup\|check>` | 1 |

The success marker's content, with mode 0644:

```
epoch=1790917727
time=2026-10-02T01:08:47-04:00
```

All four generated scripts pass `bash -n`. The failure script's heredoc
terminator renders flush-left in the store output, which was checked because
Nix indented-string stripping can break a `<<EOF` body.

---

## 6. nix-meta verification

`profiles/backup.nix` is in the `server` composition (`flake.nix:283`).
`nix-meta.backup.enable` defaults to false.

The repository's declared gate is `gitman.toml:4`:

```
verify = ["bash", "-c", "nix flake check --no-build && nix eval --raw .#nixosConfigurations.server.config.system.build.toplevel.drvPath > /dev/null"]
```

Both halves pass. Run from the Gitman workspace, so the flake reference is
`path:$PWD` rather than `.` — a jj workspace under `.worktrees/` is untracked
in the outer git tree, and Nix's git fetcher refuses it:

```
$ nix flake check --no-build "path:$PWD"
checking NixOS configuration 'nixosConfigurations.server'...
all checks passed!

$ nix eval --raw "path:$PWD#nixosConfigurations.server.config.system.build.toplevel.drvPath"
/nix/store/jgk76qyb7fvlbm0fnjiv5d65h7js1mjs-nixos-system-server-26.11.20260705.d407951.drv
```

### The change is bit-for-bit inert on the host

Trunk and the lane produce the **same** system derivation, so adding the
profile with `enable = false` changes nothing that would be activated:

```
$ nix eval --raw "git+file:///home/andrew/Documents/Projects/nix-meta?ref=refs/heads/main#nixosConfigurations.server.config.system.build.toplevel.drvPath"
/nix/store/jgk76qyb7fvlbm0fnjiv5d65h7js1mjs-nixos-system-server-…drv

$ nix eval --raw "path:$PWD#nixosConfigurations.server.config.system.build.toplevel.drvPath"
/nix/store/jgk76qyb7fvlbm0fnjiv5d65h7js1mjs-nixos-system-server-…drv
```

### The enabled path was evaluated too

Evaluating the disabled default only proves the options block. The real code
was forced with `extendModules`, setting `nix-meta.backup.enable = true`,
`postgres.enable = true`, and a stand-in `sops.secrets."restic-password"`:

```
drv: /nix/store/b745z4ha76pbqcg9ipvn6z6m5kkm60hn-nixos-system-server-…drv
```

**This found a real defect.** The check unit originally copied the backup
unit's whole `environment` attrset, which carries `PATH`.
`system/boot/systemd.nix` also defines `environment.PATH` for every unit, so
evaluation failed with a conflicting definition. The fix restricts the copy to
`RESTIC_*` keys.

Generated values, after the fix:

| Attribute | Value |
|---|---|
| `restic-backups-system` `RESTIC_REPOSITORY` | `/mnt/wd_re1/restic` |
| `restic-backups-system` `RESTIC_PASSWORD_FILE` | `/run/secrets/restic-password` |
| `restic-backups-system` `RESTIC_CACHE_DIR` | `/mnt/wd_re1/restic-cache` |
| `restic-check-system` `RESTIC_CACHE_DIR` | `/mnt/wd_re1/restic-cache` (same, by construction) |
| `RequiresMountsFor` | `/mnt/wd_re1` |
| `OnFailure` | `restic-backup-failure@%n.service` |
| `initialize` | `false` |
| `runCheck` | `false` |
| restic package | `/nix/store/blp7dnhcgl7g1jg50y4gqcj0nxj1pfp5-restic-0.19.0` |
| operator wrapper `restic-system` | present in `environment.systemPackages` |

`ExecStart` of the backup unit, in order — note the absolute store path, so no
mutable service `PATH` is involved:

```
…/restic-0.19.0/bin/restic backup --exclude-file=/nix/store/…-exclude-patterns --files-from=/run/restic-backups-system/includes
…/restic-0.19.0/bin/restic unlock
…/restic-0.19.0/bin/restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6
```

`preStart` runs the preflight first:

```
/nix/store/a7vl2kzvd86kb35q5i3v9afjjpw1i7g4-backupPrepareCommand
cat /nix/store/…-staticPaths >> /run/restic-backups-system/includes
```

Check unit:

```
ExecStartPre = /nix/store/xsz3g6bm88qcvvs98m287163p3r4fjxq-restic-preflight-system
ExecStart    = …/restic-0.19.0/bin/restic check --read-data-subset=10%
```

PostgreSQL dump unit:

```
…/restic backup --stdin-filename pg_dumpall.sql --stdin-from-command=true -- \
  …/util-linux-2.42-bin/bin/runuser -u postgres -- \
  …/postgresql-17.10/bin/pg_dumpall -h /run/postgresql --clean --if-exists
```

Timers created: `restic-backups-system`, `restic-backups-postgres`,
`restic-check-system`, `restic-backup-health`.

| Timer | `OnCalendar` | `Persistent` | Jitter |
|---|---|---|---|
| `restic-backups-system` | `02:30` | yes | 20m |
| `restic-backups-postgres` | `02:00` | yes | 10m |
| `restic-check-system` | `Sun 04:00` | yes | 30m |
| `restic-backup-health` | `09:00` | yes | 10m |

The login warning reaches `environment.interactiveShellInit`:

```
if [ -f /var/lib/restic-backup-status/last-failure ]; then
  printf '\033[1;31m!! restic backup FAILED\033[0m — %s\n' \
    "/var/lib/restic-backup-status/last-failure" >&2
  …/gnused-4.9/bin/sed -n 's/^/   /p' /var/lib/restic-backup-status/last-failure >&2
```

`/etc/zshrc` and `/etc/bashrc` both exist on this host, so the hook reaches
both shells.

---

## 7. nix-secrets verification

No `publish.verify` is configured, which `gitman doctor` reports as a warning.
Phase A deliberately left this gate out. The verification below is therefore
manual, and is the record the release needs:

```
$ bash -n scripts/*
ok scripts/bootstrap-age-key
ok scripts/secret-add
ok scripts/secret-edit
ok scripts/secret-ls
ok scripts/secret-rotate

$ nix flake check --no-build
checking NixOS module 'nixosModules.secrets'...
checking NixOS module 'nixosModules.default'...
all checks passed!        (exit 0)
```

Plus the functional tests in §4.

`nix flake check` on `nix-secrets` evaluates the flake and does **not**
decrypt `secrets/`. It cannot detect a missing secret value. That limitation
is unchanged from the Phase A decision.

---

## 8. Version-control state

### nix-secrets

```
Gitman status — CANONICAL · 1 lane
trunk: main @ b1983547c32bc85fdabdbdcefc7f5904a0423d95  (in sync with origin)
* phase-0-restic-password draft  1 change, +126 −55
```

`gitman repair` output:

```
Gitman repair — REPAIRED
re-pointed colocated git ref(s) to jj: main 58ae4ab1 -> b1983547.
```

`gitman doctor` after the repair: `colocated-refs` and `colocated-head` both
OK; the only remaining warning is the absent `publish.verify`.

**The rewound release.** `58ae4ab1` is tagged `v0.1.0` and is **ahead** of
trunk, not behind it:

```
$ git merge-base --is-ancestor b1983547 58ae4ab   →  YES (58ae4ab is ahead)
$ git log --oneline b1983547..58ae4ab
58ae4ab feat: provision deepseek-api-key; fix on-box sops authoring
$ git rev-parse origin/main
b1983547c32bc85fdabdbdcefc7f5904a0423d95
```

`58ae4ab1`'s diff against `b1983547` is the same six files as the draft lane,
`+35 −33`. A rollback rewound jj's trunk after the release; the commit survives
through its tag and its content survives on the lane. `origin/main` was
already `b1983547`, so the repair brought git into agreement with both jj and
origin. Nothing was discarded.

`nix-meta/flake.lock` pins `nix-secrets` to `rev 58ae4ab1`, `ref
refs/tags/v0.1.0`. So `nix-meta` **already** consumes the `restic-password`
declaration. Only the material is missing. The next tag must be `v0.1.1`.

**Landed and pushed.** After this evidence was gathered, lane
`phase-0-restic-password` landed into `main` and the result reached origin:

```
Gitman land — LANDED
landed phase-0-restic-password into main.
```

```
Gitman push — PUSHED
pushed main → origin @ f1aba8e2f998.
```

Trunk moved `b1983547` → `f1aba8e2`. The `v0.1.0` tag was **not** moved; it
still names `58ae4ab1`, off the current trunk, for the reason given above.
No new tag was created — see the refusal recorded in the lane table below.

### nix-meta

```
Gitman repair — REPAIRED
imported git-only history into jj: main.

Gitman status — CANONICAL · 3 lanes
trunk: main @ 1914daeb1ca86ff6ffb8da66d8fb2d98cf2f1663  (in sync with origin)
  atuin-18-23-upgrade  published  1 change, +111 −21   · 1 behind trunk
*   atuin-18-23-upgrade+server-rpath published  1 change, +217 −36   · ↳ on atuin-18-23-upgrade
  phase-0-restic-backups draft  · ws phase-0-restic-backups
```

The repair imported `1914dae` "chore: update Mnemonix to v0.1.1", which was
already on `origin/main` and on the local git `main` but not in jj. That is
ordinary catch-up on a landed, pushed commit, not another session's unlanded
work. Both Atuin lanes are published on `origin` and were not touched. They now
read `1 behind trunk` and catch up with `gitman sync` on their own schedule.

Phase 0 work is isolated in its own Gitman workspace at
`.worktrees/phase-0-restic-backups`. The shared `nix-meta` working copy, which
holds the Atuin lanes' draft content, was not edited.

**Landed and pushed.** Before landing, both halves of the gate declared in
`gitman.toml` passed again inside the lane's own workspace: `nix flake check
--no-build` and the server `drvPath` eval. The eval printed
`/nix/store/jgk76qyb7fvlbm0fnjiv5d65h7js1mjs-nixos-system-server-26.11.20260705.d407951.drv`,
the same derivation as the old trunk, which proves the change was inert.
Lane `phase-0-restic-backups` then landed into `main` and the result reached
origin. Trunk moved `1914dae` → `dddd4b19`. The laneless workspace
registration left behind was cleaned with `gitman workspace prune`; the
directory was kept, not deleted.

Both Atuin lanes were untouched throughout. They were `1 behind trunk` at
`1914dae`; after `phase-0-restic-backups` landed, they read `2 behind trunk`.
They remain published on origin.

### Lanes, commits, tags, pushes

| Repository | Lane | State |
|---|---|---|
| `nix-secrets` | `phase-0-restic-password` | **landed** into `main` (`b1983547` → `f1aba8e2`), pushed to origin |
| `nix-meta` | `phase-0-restic-backups` | **landed** into `main` (`1914dae` → `dddd4b19`), pushed to origin |

Both lanes landed and pushed. **No tag was created, and the `nix-meta`
re-pin of `nix-secrets` did not happen.** `gitman release` refuses to tag
`nix-secrets`:

```
Gitman release — REFUSED
reason: uv version --short failed: error: No `pyproject.toml` found in current directory or any parent directory
```

`gitman/src/gitman/init.py:49` gives the reason: "no pyproject.toml version
— version/release need a uv project". `gitman release --version 0.1.1`
refuses the same way, so an explicit version does not bypass the uv read.
This is by design, not a bug.

`nix-meta/flake.nix` still pins `nix-secrets` at `?ref=refs/tags/v0.1.0`,
lock rev `58ae4ab1`, unchanged. This is now a fourth, open blocker — see
`IMPLEMENTATION.md` §B4 and `DESIGN.md` §12.

---

## 9. Backup scope

Source size, measured earlier and treated as a **lower bound** because some
root-only paths were unreadable:

| Path | Bytes |
|---|---|
| `/home/andrew` | 94,439,153,664 |
| `/etc` | 688,128 |
| `/var/lib` | 20,609,769,472 |
| **Total** | **115,049,611,264** (about 107.1 GiB) |

Docker, measured 2026-10-02 (`docker system df`):

| Type | Total | Active | Size | Reclaimable |
|---|---|---|---|---|
| Images | 13 | 3 | 17.88 GB | 13.06 GB (73%) |
| Containers | 3 | 1 | 42.11 MB | 0 B |
| Local volumes | 7 | 3 | 582.1 MB | 155.9 MB (26%) |
| Build cache | 84 | 0 | 36.37 GB | 25.59 GB |

Seven local volumes exist. `mnemonix-hindsight-data` is one of them and is
**in** the backup, under `/var/lib/docker/volumes`. A file-level restore of it
does not prove Hindsight application consistency.

Paths: `/home/andrew`, `/etc`, `/var/lib`.

Excludes: `/home/andrew/.cache`, `**/.devenv`, `**/target`, `**/.venv`,
`**/node_modules`, `**/.worktrees`, `/var/lib/docker/overlay2`,
`/var/lib/docker/buildkit`.

`/mnt/shared` is **out of scope** and was not moved, deleted, or modified.
Phase F stays blocked until it has a separate verified policy.

---

## 10. PostgreSQL

Read from the live unit (`systemctl cat postgresql.service`, `systemctl show`):

| Fact | Value |
|---|---|
| State | `active` |
| Version | PostgreSQL 17.10 |
| `PGDATA` | `/var/lib/postgresql/17` |
| `User` / `Group` | `postgres` / `postgres` |
| `RuntimeDirectory` | `postgresql`, so the socket is `/run/postgresql` |
| `StateDirectoryMode` | `0750` |
| Config | `machines/server.nix:318`, `package = pkgs.postgresql_17` |

Authentication, read from the nixpkgs module rather than from the generated
`pg_hba.conf`, which is root-only:

```
nixpkgs/nixos/modules/services/databases/postgresql.nix:692
  local all postgres         peer map=postgres
  local all all              peer
nixpkgs/nixos/modules/services/databases/postgresql.nix:701
  identMap (default): postgres postgres postgres
```

root is **not** in the `postgres` ident map, so root cannot connect as the
`postgres` role. The dump must run as the `postgres` OS user. That is settled.

**What is not settled:** the job has never run. `pg_hba.conf` itself was not
read, the dump was not produced, and no restore was attempted. The job is
therefore shipped **disabled** (`nix-meta.backup.postgres.enable`, default
false) and `/var/lib/postgresql` stays **inside** the file backup until an
operator proves the dump. `IMPLEMENTATION.md` step C11 holds the proof
command.

A file-level copy of a live cluster is **not** a valid database backup. That
claim is not made anywhere in this change.

---

## 11. Privilege

`sudo` cannot authenticate in this session:

```
$ sudo -n true
sudo: a password is required
```

`/run/wrappers/bin/sudo` is correct (`r-s--x--x root`, setuid set). The journal
shows a session at `Oct 01 21:50:29` hitting the same refusal, so this is a
standing condition, not a defect introduced here.

Every item in §1's gate needs root. That is blocker B2.

---

## 12. Still to record

When steps C1 and C6 to C10 run, add to this document:

- the WD Re long SMART result, in full
- how the WD Green repository was handled, and both restic key IDs from C2
- the repository path, snapshot ID, source size, stored size
- the `restic check` result
- the restored paths, the `cmp` results, and the restored host key's
  owner, group and mode
- `systemctl list-timers 'restic*'` for the backup, check and health timers
- the failure-path proof from C10

Record no secret contents, no password value, and no private-key content.
