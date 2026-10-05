# Phase 0 implementation — ordered steps

Legend: **[done]** verified in `EVIDENCE.md` · **[blocked]** needs an operator
action · **[ready]** the command exists and runs once its blocker clears ·
**[superseded]** the step was written for the password-based design and is
no longer needed; kept, struck through, as history.

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

No blocker remains. B2 (interactive `sudo`) is resolved: the operator ran
the privileged steps directly, on 2026-10-04 (see `EVIDENCE.md` §16). B1
is resolved by decision, not by hardware. B3 is resolved by the
passwordless design, not by an off-host recipient. B4 was resolved earlier
by a hand-made tag. Numbering stays as originally assigned; no blocker
number is reused or dropped.

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

### B2. A session where `sudo` can authenticate **[resolved: operator ran it]**

Every privileged step needs it. `sudo` refused in every earlier automated
session:

```
sudo: a password is required
```

The journal showed a session at `Oct 01 21:50:29` hitting the same
refusal, so that was not new. The operator ran the privileged steps
directly, from an interactive terminal, on 2026-10-04. See `EVIDENCE.md`
§16 for the measured result. No blocker remains.

### B3. An off-host SOPS recipient **[resolved: passwordless design]**

Superseded, not merely deferred. This blocker existed because both SOPS
recipients for `restic-password` lived on the host the backup protects
(`DESIGN.md` §3, prior text, kept there as history). The user chose the
passwordless design instead: there is no `restic-password` secret, so there
is nothing for an off-host recipient to protect. No recipient was added,
and none needs to be. See `DESIGN.md` §2 and §3 for the resolution and its
trade-off.

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

### C1. Adjudicate the existing WD Green repository **[done]**

`/mnt/wd_green1/restic` exists, `root:root 0700`, created 2026-09-28 22:51 by
restic 0.19.0 with `--insecure-no-password`. The filesystem holds 59 GB, which
is almost certainly that repository, but the journal records only the `sudo`
invocation, so **completion is unproven**.

**Done, 2026-10-04.** All three commands below were run. `snapshots`
listed two snapshots (`3dd34831` and `26236227`), `check` succeeded, and
`stats` reported source sizes matching `EVIDENCE.md` §16's table.
Completion is proven, not merely likely.

Read-only first. Nothing here writes to the repository.

```bash
restic_bin="$(nix build --no-link --print-out-paths 'nixpkgs#restic')/bin/restic"

sudo "$restic_bin" --repo /mnt/wd_green1/restic --insecure-no-password \
  --no-lock --no-cache snapshots --json

sudo "$restic_bin" --repo /mnt/wd_green1/restic --insecure-no-password \
  --no-lock --no-cache check --read-data-subset=10%

sudo "$restic_bin" --repo /mnt/wd_green1/restic --insecure-no-password \
  --no-lock --no-cache stats latest --mode restore-size
```

- **All three succeed** → keep the repository as-is, on its original
  `--insecure-no-password` key (`DESIGN.md` §2). There is no key swap to run.
  Do not create a second repository beside it.
- **The check fails** → leave it exactly as it is, unchanged, and use a clean
  repository on the selected WD Re disk.
- **Unexpected snapshots or paths appear** → stop and report before anything
  else.

### C1b. Add a human recovery key, while the repository still has no password **[superseded]**

Superseded: the passwordless design (`DESIGN.md` §2, §3) removed the need.
There is no restic password and no restic key at all, so there is nothing
for a human-held recovery key to be an alternative to. Kept here, struck
through, so the prior design is visible in history rather than silently
gone.

~~This step must run before C4, while the repository's only key is still the
empty `--insecure-no-password` key from C1. It adds a second restic key whose
passphrase a human holds — the supplementary path from `DESIGN.md` §3, not
the primary recovery path. Run it before C2 removes the empty key, because
this step authenticates against that same empty key.~~

~~Replace `RECOVERY_USER` and `RECOVERY_HOST` with values that will still be
readable in five years. `key list` shows only `ID / User / Host / Created`,
with the current key marked `*` — there is no label or purpose field, so
`--user` and `--host` are the only way to tell keys apart later.~~

~~Run this at a genuine interactive terminal. A console or a normal SSH
session is fine; a script that pipes stdin is not. The passphrase itself
must be 7 words from the EFF long wordlist, never fewer than 6, generated by
dice or a tool — never invented by hand.~~

### C2. Give the WD Green repository a real password **[superseded]**

Superseded: the passwordless design (`DESIGN.md` §2) removed the need. The
repository stays on its original `--insecure-no-password` key; there is no
add/verify/remove key swap to perform.

~~Add, verify, then remove. Never a blind replacement, and never remove the
old key before the new one is proved.~~

### C3. Add the off-host recipient **[superseded]**

Superseded: the passwordless design (`DESIGN.md` §3) removed the need. There
is no `restic-password` secret left for an off-host recipient to protect, so
blocker B3 is resolved by this same change, not merely deferred — see §B3
above.

~~Add the off-host recipient from B3 to `secrets/.sops.yaml`, then re-encrypt
the whole store to the new recipient set, and prove the off-host identity
can open it.~~

### C4. Provision `restic-password` **[superseded]**

Superseded: the passwordless design (`DESIGN.md` §2) removed the need. No
value was ever generated for this secret, and none needs to be.

~~Generate the secret straight into the `nix-secrets` store, verify, land, and
push; then tag the release and re-pin `nix-meta` to it.~~

The one piece of this step that did happen for an unrelated reason —
`nix-secrets` is tagged `v0.1.1` (annotated tag, tag object `3ecc2a60`,
commit `f1aba8e2`) and `nix-meta` is pinned to it — stays true and is
unaffected by this change: both tags declare the same `restic-password`
name in `nix-secrets`'s canonical inventory, and that declaration is simply
unused now (`DESIGN.md` §2). See `EVIDENCE.md` §8 for the historical
before/after record of that re-pin.

### C5. Activate the secret on `server` **[superseded]**

Superseded: the passwordless design (`DESIGN.md` §2) removed the need.
There is no secret to activate. `nix-meta.backup.enable = true`
(`machines/server.nix`) already creates real backup units on its own, with
no `nix-secrets.secrets.activeNames` entry and no `sops.secrets` entry
required.

~~Add `"restic-password"` to `nix-secrets.secrets.activeNames`, verify, land
and push, then prove the secret arrived at `/run/secrets/restic-password`.~~
Steps 1 and 2 of the original step (the `v0.1.1` re-pin) happened for an
unrelated reason and are unaffected; see C4 above.

### C6. Confirm the repository, do not initialize one **[done]**

There is nothing to initialize. The repository at `/mnt/wd_green1/restic`
already exists (C1), with its original `--insecure-no-password` key. This
step is a confirmation, not a write: prove the mount is real, prove it is
not the root filesystem, and prove the repository responds — with no
password file, since the design is passwordless (`DESIGN.md` §2).

```bash
mount=/mnt/wd_green1
repo="$mount/restic"
restic_bin="$(nix build --no-link --print-out-paths 'nixpkgs#restic')/bin/restic"

# Refuse to continue unless the mount is real and is not the root filesystem.
mountpoint -q "$mount" || { echo "ABORT: $mount is not a mount point"; exit 1; }
[ "$(stat -c %d /)" != "$(stat -c %d "$mount")" ] \
  || { echo "ABORT: $mount is the root filesystem"; exit 1; }
echo "target: $repo"; findmnt "$mount"

# Confirm the repository answers, passwordless.
sudo "$restic_bin" --repo "$repo" --insecure-no-password cat config
```

**Until this step's repository confirmation holds**, every `nixos-rebuild
switch` on this host prints the activation-time warning added at
`profiles/backup.nix:597` (`system.activationScripts.resticBackupNeedsInitWarning`):
a multi-line note to stderr naming the repository path and the exact command
to create one, then `exit 0`. That is expected, not a fault — it is the same
loud-but-harmless signal the preflight check gives at run time, just earlier.
It stops appearing once the repository this step confirms actually exists and
has a `config` file.

**Done, 2026-10-04.** `restic cat config` succeeded. The repository is
confirmed, so the activation-time warning described above no longer
appears. See `EVIDENCE.md` §16.

### C7. Activate and inspect **[done]**

The option block itself is already landed on trunk (`machines/server.nix`,
`nix-meta.backup.enable = true`, `mountPoint = "/mnt/wd_green1"`). This step
no longer adds it. It activates the rebuild and inspects what was generated.

**Activate by the exact pinned commit, not by the short flake reference.**
The shared working copy of `nix-meta` on this host sits on an Atuin lane,
behind trunk. The short form, `--flake '.#server'`, resolves against
whatever is checked out in that working copy, so it silently builds the
lane instead of trunk, with no warning that it did so. That form has
already cost two rebuilds and produced an activation with no restic units
at all. Pin the flake reference to trunk explicitly instead:

```bash
nix flake check --no-build
nix eval --raw '.#nixosConfigurations.server.config.system.build.toplevel.drvPath' > /dev/null
sudo nixos-rebuild switch --flake 'git+file:///home/andrew/Documents/Projects/nix-meta?ref=refs/heads/main#server'

systemctl cat restic-backups-system.service
systemctl cat restic-check-system.service
systemctl list-timers 'restic*'
systemctl show restic-backups-system.service \
  -p RequiresMountsFor -p OnFailure -p ExecStart -p ExecStartPost
```

`systemctl cat` is enough; there is no password file path to avoid dumping.

**Before the repository at `/mnt/wd_green1/restic` is confirmed (C6)**, this
same rebuild prints the activation-time missing-repository warning (see the
note under C6). Once C6's repository confirmation holds, the warning stops
and `systemctl cat` shows the real units below — which this design creates
unconditionally once `nix-meta.backup.enable = true`, with no secret-arrival
gate.

**Done, 2026-10-04.** System generation 134, store path
`rgzc6m0z55iygpjzbs6g87xh66k87c8b-nixos-system-server-26.11.20260705.d407951`.
`/run/current-system` and the system profile now agree, so the split state
left by the `EVIDENCE.md` §15.3 activation failure is resolved. See
`EVIDENCE.md` §16.

### C8. The restore gate **[done — PASSED]**

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
repository and the cache directory, and it runs the same wrapped,
flag-injecting restic package as the service, so it cannot reach a
different repository and cannot prompt for a password.

**Done, 2026-10-04 — PASSED.** Run from snapshot `26236227` into
`/tmp/restic-restore.MelxhTWB`. All three files restored, non-empty, and
`cmp` OK against the live files; the SSH host key came back `root:root
0600`. The restore directory held a private SSH host key; the operator
was given the exact resolved-path removal command shown above. Removal is
not verified here — do not assume it ran. See `EVIDENCE.md` §16 for the
full record.

### C9. The weekly check **[done]**

```bash
sudo systemctl start restic-check-system.service
systemctl status restic-check-system.service
cat /var/lib/restic-backup-status/last-success-check
```

**Done, 2026-10-04.** `restic-check-system.service` succeeded, started
04:09:16, finished 04:10:47 EDT. See `EVIDENCE.md` §16.

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
