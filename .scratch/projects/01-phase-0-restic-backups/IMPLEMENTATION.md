# Phase 0 implementation — ordered steps

Legend: **[done]** verified in `EVIDENCE.md` · **[blocked]** needs an operator
action · **[ready]** the command exists and runs once its blocker clears.

Run every version-control action through Gitman, from Gitman's own environment:

```bash
cd ~/Documents/Projects/gitman && devenv shell -- bash -c 'cd <repo> && gitman <verb>'
```

Never run `devenv` with `nix-meta` or `nix-secrets` as the working directory.

---

## A. Repository work — done

### A1. Repair `nix-secrets` **[done]**

`gitman repair` re-pointed the colocated git ref for `main` from `58ae4ab1` to
`b1983547`, matching `origin/main`. Status is CANONICAL with one lane. See
`DESIGN.md` §10 for why the git ref was ahead.

### A2. Fix the secret tooling **[done]**

- `scripts/secret-add` reads the value from **stdin only** and passes it to
  `sops set --value-stdin`. The old code put JSON-encoded plaintext in the
  `sops` process arguments, where `ps` and `/proc/<pid>/cmdline` expose it. The
  value-as-argument form is removed for the same reason. Exit codes are
  `0` set, `1` store unchanged, `2` usage.
- `scripts/secret-ls` lists all ten canonical names. It listed seven.
- `modules/secrets.nix` drops two comment counts that still said eight.
- `RUNBOOK.md` gains the stdin contract and §3a, the recipient-coverage
  constraint.

`sops` 3.13.3 requires **JSON** on stdin as well as in the argument form. That
was measured, not assumed; see `EVIDENCE.md` §4.

### A3. Author the backup profile **[done]**

- `nix-meta/profiles/backup.nix` — new.
- `nix-meta/profiles/default.nix` — exports `backup`.
- `nix-meta/flake.nix:283` — `profiles.backup` sits after `profiles.secrets` in
  the `server` composition.

`nix-meta.backup.enable` defaults to **false**, so the profile creates no
units and nothing on the host changed. Both halves of nix-meta's verify gate
pass with the profile in the composition; see `EVIDENCE.md` §6.

---

## B. Blockers — operator actions

Two blockers remain: B2 (interactive `sudo`) and B3 (the off-host SOPS
recipient). B1 is resolved by decision, not by hardware. B4 was resolved
earlier by a hand-made tag. Numbering stays as originally assigned; no
blocker number is reused or dropped.

### B1. Target disk **[resolved: decision]**

The user chose `/mnt/wd_green1` as the Phase 0 target, now, instead of
waiting for a WD Re disk. See `DESIGN.md` §1. This is no longer a blocker.

`lsblk` shows no WD Re device. Only `sda` (WD Green), `sdb` (Team SATA),
`nvme0n1` (empty 4 TB) and `nvme1n1` (system) are present. Both WD Re UUIDs
are declared with `nofail`, so the host boots without them and leaves empty
directories at `/mnt/wd_re1` and `/mnt/wd_re2`. Both stay declared and both
stay the preferred upgrade path.

**The WD Re upgrade path, when a disk is seated.** Seat a WD Re
`WD2000FYYZ` in a flexbay, then:

```bash
# 1. Find it. Expect a WD2000FYYZ.
lsblk -o NAME,SIZE,TYPE,FSTYPE,UUID,MODEL

# 2. Start a long SMART test. It takes about 4 hours on a 2 TB 7200 rpm disk
#    and runs in the background; the disk stays usable.
sudo smartctl -t long /dev/sdX

# 3. Hours later, read the result. Report the whole block.
sudo smartctl -a /dev/sdX
```

Accept the disk only when the self-test log shows `Completed without error`
and `Reallocated_Sector_Ct`, `Current_Pending_Sector` and
`Offline_Uncorrectable` are all zero. Prefer WD Re 1. Use WD Re 2 only if
WD Re 1 fails and WD Re 2 passes.

Then confirm the declared UUID still matches, and that the mount came up:

```bash
findmnt /mnt/wd_re1
df -h /mnt/wd_re1
```

If the UUID changed, `machines/server.nix:637` needs the new one before
anything else. Moving the profile's `mountPoint` back to a WD Re disk, once
one is proved, is a one-line change in `machines/server.nix`.

### B2. A session where `sudo` can authenticate **[blocked: password]**

Every privileged step needs it. `sudo` currently refuses:

```
sudo: a password is required
```

The journal shows a session at `Oct 01 21:50:29` hitting the same refusal, so
this is not new. Run the privileged steps from an interactive terminal.

### B3. An off-host SOPS recipient **[blocked: decision]**

Both current recipients live on this host. See `DESIGN.md` §3. Nothing was
invented and no recipient was added.

Decide one of these and report which:

**Option 1 — a laptop or other host.** Run on that machine:

```bash
cd ~/Documents/Projects/nix-secrets
devenv shell -- ./scripts/bootstrap-age-key    # prints one age1… line
```

Send the `age1…` line. It is a public key; it is safe to paste.

**Option 2 — a hand-held age key kept off this box.** On any machine:

```bash
age-keygen -o restic-recovery.key     # keep the file OFF this host
age-keygen -y restic-recovery.key     # the age1… line to send
```

**Option 3 — password-manager escrow only, no third recipient.** State this
explicitly. The password is then readable once with
`sops -d --extract '["restic-password"]'` and must be stored off-host by hand.
Option 3 alone leaves no way to decrypt the rest of the store after host loss.

### B4. A version source for `nix-secrets`, so it can be tagged **[resolved: hand tag]**

`gitman release` refuses to tag `nix-secrets`:

```
Gitman release — REFUSED
reason: uv version --short failed: error: No `pyproject.toml` found in current directory or any parent directory
```

`gitman/src/gitman/init.py:49`: "no pyproject.toml version — version/release
need a uv project". An explicit version does not bypass this:
`gitman release --version 0.1.1` refuses the same way. `nix-secrets` has no
`pyproject.toml`, so `gitman` has no version source to read.

Three options, described with trade-offs in `DESIGN.md` §12:

1. Add a minimal `pyproject.toml` and `uv.lock` to `nix-secrets`, so
   `gitman release` works.
2. Tag by hand with raw `git tag -a`, once per release.
3. Pin `nix-meta`'s `nix-secrets` input by `rev` instead of by tag.

**Resolution.** The user chose option 2 and tagged `nix-secrets` by hand:
annotated tag `v0.1.1`, tag object `3ecc2a60`, commit `f1aba8e2`, pushed to
origin. An agent could not do this step: the permission classifier refused
the same `git tag` command, because the gitman-only rule lives in this
repository's own `AGENTS.md`. `nix-meta` now pins `v0.1.1` (see C4). The
underlying gap — `gitman` cannot tag a repository with no `uv` project — is
filed at
`~/Documents/Projects/gitman/.scratch/projects/63-non-python-repo-versioning/ISSUE.md`.
Until `gitman` closes that gap, this hand-tag exception must be re-granted
by the user at every `nix-secrets` release.

---

## C. Steps that run once B clears

### C1. Adjudicate the existing WD Green repository **[ready, needs B2]**

`/mnt/wd_green1/restic` exists, `root:root 0700`, created 2026-09-28 22:51 by
restic 0.19.0 with `--insecure-no-password`. The filesystem holds 59 GB, which
is almost certainly that repository, but the journal records only the `sudo`
invocation, so **completion is unproven**.

Read-only first. Nothing here writes to the repository.

```bash
restic_bin="$(nix build --no-link --print-out-paths nixpkgs#restic)/bin/restic"

sudo "$restic_bin" --repo /mnt/wd_green1/restic --insecure-no-password \
  --no-lock --no-cache snapshots --json

sudo "$restic_bin" --repo /mnt/wd_green1/restic --insecure-no-password \
  --no-lock --no-cache check --read-data-subset=10%

sudo "$restic_bin" --repo /mnt/wd_green1/restic --insecure-no-password \
  --no-lock --no-cache stats latest --mode restore-size
```

- **All three succeed** → keep the repository as the secondary copy and secure
  it in C2. Do not create a second repository beside it.
- **The check fails** → leave it exactly as it is, unchanged, and use a clean
  repository on the selected WD Re disk.
- **Unexpected snapshots or paths appear** → stop and report before anything
  else.

### C2. Give the WD Green repository a real password **[ready, needs B2 and C4]**

Add, verify, then remove. Never a blind replacement, and never remove the old
key before the new one is proved.

```bash
restic_bin="$(nix build --no-link --print-out-paths nixpkgs#restic)/bin/restic"
repo=/mnt/wd_green1/restic

# 1. Record the current key ID. Keep this output.
sudo "$restic_bin" --repo "$repo" --insecure-no-password key list

# 2. Add a key from the decrypted password file.
sudo "$restic_bin" --repo "$repo" --insecure-no-password \
  key add --new-password-file /run/secrets/restic-password

# 3. Prove the password-file form opens the repository.
sudo "$restic_bin" --repo "$repo" \
  --password-file /run/secrets/restic-password snapshots

# 4. Remove the old empty-password key BY ITS EXACT ID from step 1.
sudo "$restic_bin" --repo "$repo" \
  --password-file /run/secrets/restic-password key remove <OLD_ID>

# 5. Prove the empty password no longer works. Expect exit code 12.
sudo "$restic_bin" --repo "$repo" --insecure-no-password snapshots
echo "exit=$?"   # 12 means the repository refused the empty password
```

Record both key IDs in `EVIDENCE.md`. Record neither password.

### C3. Add the off-host recipient **[ready, needs B3]**

Lane `phase-0-restic-password` has since landed and pushed as part of step
C4; see `EVIDENCE.md` §8. Only B3's decision and this re-encryption step
remain open.

```bash
# 1. Add the off-host recipient from B3 to secrets/.sops.yaml, then re-encrypt
#    the whole store to the new recipient set.
cd ~/Documents/Projects/nix-secrets
devenv shell -- ./scripts/secret-rotate --updatekeys

# 2. Prove the off-host identity can open the store. The value is discarded.
SOPS_AGE_KEY_FILE=<off-host-identity> \
  devenv shell -- sops -d secrets/secrets.yaml > /dev/null && echo OFF_HOST_OK
```

### C4. Provision `restic-password` **[landed, pushed, released, re-pinned]**

The secret was generated straight into the store. Nobody read it, and it
never reached a terminal, a log, or a shell history:

```bash
cd ~/Documents/Projects/nix-secrets
head -c 32 /dev/urandom | base64 -w0 \
  | devenv shell -- ./scripts/secret-add restic-password

devenv shell -- ./scripts/secret-ls | grep restic-password   # STORE must read "yes"
```

Verified, landed and pushed:

```bash
cd ~/Documents/Projects/nix-secrets && nix flake check --no-build

cd ~/Documents/Projects/gitman && devenv shell -- bash -c '
  cd ~/Documents/Projects/nix-secrets &&
  gitman land && gitman push'
```

`nix-secrets` has no `publish.verify`, so the verification above is manual and
is recorded in `EVIDENCE.md` §8. Trunk moved `b1983547` → `f1aba8e2`.

**The release has happened.** `gitman release` still cannot tag
`nix-secrets` — `uv version --short` still fails, blocker B4 (see §B4 above
and `DESIGN.md` §12). The user tagged by hand instead: `v0.1.1` is an
annotated tag, tag object `3ecc2a60`, pointing at commit `f1aba8e2`, which is
`nix-secrets` trunk tip. The tag is pushed to origin. `v0.1.0` is unchanged,
still at `58ae4ab1`, still not on trunk (`DESIGN.md` §10).

**`nix-meta` now pins it.** `flake.nix:77` reads
`?ref=refs/tags/v0.1.1`, and `flake.lock`'s `nix-secrets` node locks `ref
refs/tags/v0.1.1` / `rev f1aba8e2`. Only the `nix-secrets` node moved in the
lock. This is correctness hygiene, not a functional change: both `v0.1.0`
and `v0.1.1` carry the same `restic-password` declaration, and the backup
profile stays inert (`restic-password` still has no encrypted material, so
no `restic.*` systemd timer exists). See `EVIDENCE.md` §8 for the full
before/after record.

### C5. Activate the secret on `server` **[ready, needs C4]**

A separate, secret-only `nix-meta` lane, in its own workspace:

```bash
cd ~/Documents/Projects/gitman && devenv shell -- bash -c '
  cd ~/Documents/Projects/nix-meta &&
  gitman start phase-0-activate-restic-secret --workspace'
```

Steps 1 and 2 below are **already done**, landed on trunk by a separate
re-pin lane (see C4 and `EVIDENCE.md` §8). Steps 3 through 5 remain.

In that workspace:

1. ~~Point `flake.nix:77` at `?ref=refs/tags/v0.1.1`.~~ **Done.**
2. ~~`nix flake lock --update-input nix-secrets`.~~ **Done.**
3. Add `"restic-password"` to `nix-secrets.secrets.activeNames` at
   `profiles/secrets.nix:27`.
4. Verify, then land and push:

```bash
nix flake check --no-build
nix eval --raw .#nixosConfigurations.server.config.system.build.toplevel.drvPath > /dev/null
sudo nixos-rebuild switch --flake .#server
```

5. Prove the secret arrived. This is the gate for step C6:

```bash
sudo stat -c '%n %U:%G %a' /run/secrets/restic-password
# must print: /run/secrets/restic-password root:root 400
```

### C6. Confirm the repository, do not initialize one **[ready, needs B2, C2, C5]**

There is nothing to initialize. The repository at `/mnt/wd_green1/restic`
already exists (C1), and C2 already replaced its empty password with a real
one. This step is a confirmation, not a write: prove the mount is real, prove
it is not the root filesystem, and prove the repository responds through the
password file now that `restic-password` has material (C5).

```bash
mount=/mnt/wd_green1
repo="$mount/restic"
restic_bin="$(nix build --no-link --print-out-paths nixpkgs#restic)/bin/restic"

# Refuse to continue unless the mount is real and is not the root filesystem.
mountpoint -q "$mount" || { echo "ABORT: $mount is not a mount point"; exit 1; }
[ "$(stat -c %d /)" != "$(stat -c %d "$mount")" ] \
  || { echo "ABORT: $mount is the root filesystem"; exit 1; }
echo "target: $repo"; findmnt "$mount"

# Confirm the repository answers through the password file sops-nix wrote.
sudo "$restic_bin" --repo "$repo" \
  --password-file /run/secrets/restic-password cat config
```

### C7. Activate and inspect **[ready, needs C5, C6]**

The option block itself is already landed on trunk (`machines/server.nix`,
`nix-meta.backup.enable = true`, `mountPoint = "/mnt/wd_green1"`). This step
no longer adds it. It activates the rebuild and inspects what was generated.

```bash
nix flake check --no-build
nix eval --raw .#nixosConfigurations.server.config.system.build.toplevel.drvPath > /dev/null
sudo nixos-rebuild switch --flake .#server

systemctl cat restic-backups-system.service
systemctl cat restic-check-system.service
systemctl list-timers 'restic*'
systemctl show restic-backups-system.service \
  -p RequiresMountsFor -p OnFailure -p ExecStart -p ExecStartPost
```

Do not dump the unit's full environment: it names the password file path among
values that can include secrets elsewhere. `systemctl cat` is enough.

**Before `restic-password` has encrypted material**, this rebuild prints the
profile's own warning and creates no `restic.*` unit at all. That is
expected — it is the loud-but-inert state the profile is designed to produce,
not a failure. Units appear only after C4 and C5 give the secret real
material.

### C8. The restore gate **[ready, needs C7]**

```bash
sudo systemctl start restic-backups-system.service
systemctl status restic-backups-system.service

snapshot_id="$(sudo restic-system snapshots --json --latest 1 | jq -er '.[0].id')"
echo "snapshot: $snapshot_id"

restore_dir="$(mktemp -d /tmp/restic-restore.XXXXXXXX)"
chmod 0700 "$restore_dir"

sudo restic-system restore "$snapshot_id" \
  --target "$restore_dir" \
  --include /home/andrew/Documents/Projects/nix-meta/AGENTS.md \
  --include /etc/ssh/ssh_host_ed25519_key \
  --include /var/lib/nixos/declarative-users

for f in /home/andrew/Documents/Projects/nix-meta/AGENTS.md \
         /etc/ssh/ssh_host_ed25519_key \
         /var/lib/nixos/declarative-users; do
  r="$restore_dir$f"
  sudo test -s "$r"              && echo "non-empty: $f" || echo "EMPTY/MISSING: $f"
  sudo cmp --silent "$r" "$f"    && echo "cmp OK:    $f" || echo "cmp FAIL:   $f"
done

# The host key must come back root:root 0600.
sudo stat -c '%n %U:%G %a' "$restore_dir/etc/ssh/ssh_host_ed25519_key"

# Record everything above in EVIDENCE.md, then remove the directory. It holds
# a private SSH host key. Use the exact resolved path, never a wildcard.
echo "removing $restore_dir"
sudo rm -rf -- "$restore_dir"
```

`restic-system` is the wrapper the NixOS module generates. It carries the
repository, the password file and the cache directory, so the command cannot
reach a different repository than the service does.

### C9. The weekly check **[ready, needs C7]**

```bash
sudo systemctl start restic-check-system.service
systemctl status restic-check-system.service
cat /var/lib/restic-backup-status/last-success-check
```

### C10. Prove the failure path **[ready, needs C7]**

The failure signal is worth as much as the backup. Prove it on purpose.

**Caution.** Unmounting `/mnt/wd_green1` takes the live repository offline.
Run this proof only when no backup or check is running.

```bash
# Unmount the backup disk, then run the backup. It must fail at preflight.
sudo umount /mnt/wd_green1
sudo systemctl start restic-backups-system.service   # expect a failure
cat /var/lib/restic-backup-status/last-failure
journalctl -u restic-backups-system.service -n 20 --no-pager

# The marker must warn on a new interactive login.
bash -ic true

# Remount, run a real backup, and confirm the marker clears.
sudo mount /mnt/wd_green1
sudo systemctl start restic-backups-system.service
ls /var/lib/restic-backup-status/      # last-failure must be gone
```

### C11. The PostgreSQL dump **[ready, needs C7, unproven]**

Only after C8 passes. It is off by default and has never run.

```nix
nix-meta.backup.postgres.enable = true;
```

```bash
sudo systemctl start restic-backups-postgres.service
sudo restic-system snapshots --json | jq -r '.[].paths[]' | sort -u
# expect an entry for pg_dumpall.sql
```

Keep `/var/lib/postgresql` **inside** the file backup until this is proved.
See `DESIGN.md` §9.

---

## D. Not in Phase 0

- `/mnt/shared` — 129 GiB, unadjudicated. Phase F stays blocked until it has
  its own verified policy. Nothing there was moved, deleted, or modified.
- Mnemonix Hindsight application consistency — unsolved, and it must be settled
  before Phase E.
- A remote notification channel — none exists, and none was claimed.
