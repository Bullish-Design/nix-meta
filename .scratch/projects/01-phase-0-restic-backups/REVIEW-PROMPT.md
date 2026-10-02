# Review: Phase 0 restic backups — audit and report only

Your job is to review the Phase 0 restic-backup work and report where it
stands. Verify claims against the code, the commits, and the gate. Do not
implement anything and do not fix anything you find. Produce a report.

## Hard boundaries

- Do not modify any repository.
- Run no `gitman` mutation verb (no `save`, `land`, `push`, `release`, or
  similar). Read-only `gitman status` and `gitman doctor` are fine.
- Run no `sudo`, no `nixos-rebuild`, no `restic`, no `sops`.
- You may read anything and run read-only commands: `nix flake check`,
  `nix eval`, `git show` (read-only forms), `cat`, `grep`, `systemctl
  show`/`list-timers`/`list-units` (read-only), `df`, `lsblk`.
- Never display or record secret material, password values, or private-key
  contents.
- Write in Simplified Technical English: short sentences, active voice, one
  word per meaning. No AI attribution anywhere in your report.

## Relationship to the other Phase 0 prompt

`nix-meta/.scratch/projects/01-phase-0-restic-backups/NEXT-SESSION-KICKOFF.md`
is a separate, already-written prompt for a different session. That session
investigates and plans the *remaining* work: the two blockers, the untested
preflight/failure/check/restore/postgres units, the umbrella-guide open
decisions, and Phase B–F sequencing. Read it so you understand what it
covers, but do not redo its job. Where your review touches the same ground
— the two blockers, the untested units — state the fact briefly and point at
`NEXT-SESSION-KICKOFF.md` for the planning. Your value is verification, not
planning: did the prior session's claims hold up, and what did it get wrong.

## Read these first

- All five documents in
  `~/Documents/Projects/nix-meta/.scratch/projects/01-phase-0-restic-backups/`:
  `README.md`, `DESIGN.md`, `IMPLEMENTATION.md`, `EVIDENCE.md`,
  `NEXT-SESSION-KICKOFF.md`. The shared `nix-meta` working copy sits on an
  Atuin lane 9 behind trunk, so these files are not on disk in the main
  checkout. Read them from trunk, for example:
  `git show main:.scratch/projects/01-phase-0-restic-backups/DESIGN.md`.
  A lane worktree under `.worktrees/` is a second source if one exists.
- `nix-meta/profiles/backup.nix` and the `nix-meta.backup` block in
  `nix-meta/machines/server.nix`, read from trunk the same way.
- `~/Documents/Projects/vendomat/.scratch/projects/07-local-depot-release-bus/IMPLEMENTATION.md`
  — the umbrella guide; Phase 0 is one phase of it.
- `~/Documents/Projects/gitman/.scratch/projects/63-non-python-repo-versioning/ISSUE.md`
  — a gap filed during the work, written but uncommitted.
- `nix-meta/CLAUDE.md` and `nix-secrets/AGENTS.md`.

## Verification tasks

Do these first. They set a critical frame before you read the background
facts below, which the prior session asserts rather than proves.

### 1. Verify the commit inventory

These commits belong to the Phase 0 session. For each, confirm it exists,
confirm it is on `origin`, and read its diff to confirm it does what its
message claims. Flag any mismatch between message and diff.

`nix-meta`, trunk now `558c3941ed500adbe125b4136cb715016d2d5663`, series
parent `1914dae`:

| Commit | Claim |
|---|---|
| `dddd4b1` | feat: add the restic backup profile (Phase 0, inert) |
| `d633a35` | fix: keep Hindsight model provider disabled — not ours, another session's mnemonix bump landed mid-work |
| `b8508a9` | docs: record the Phase 0 lanes as landed, and open the tagging gap |
| `092075f` | fix: pin nix-secrets to released trunk tag v0.1.1 |
| `55f5a65` | docs: correct why the v0.1.1 re-pin left the derivation unchanged |
| `991566a` | feat: retarget Phase 0 backup to the WD Caviar Green |
| `db300d1` | docs: date-stamp the unit-value probe in EVIDENCE.md |
| `558c394` | docs: fix Phase 0 doc defects and add the recovery-key design |

`nix-secrets`, trunk `f1aba8e2f998bf620c19c5ea8dee52d4f026bc89`: one commit,
`f1aba8e` "feat: declare restic-password; make secret-add leak-proof".
Tags: `v0.1.0` lightweight on `58ae4ab1` (off trunk — confirm it has not
moved), `v0.1.1` annotated on `f1aba8e2`, pushed to origin.

Confirm both tags exist on origin and point where claimed.

### 2. Re-verify the gate, independently

`nix-meta/gitman.toml` declares a gate of `nix flake check --no-build` plus
`nix eval --raw '.#nixosConfigurations.server.config.system.build.toplevel.drvPath'`.
The expected derivation is
`/nix/store/wbjk6lr9jz371zq56ai8q2wjd6ab9nmn-nixos-system-server-26.11.20260705.d407951.drv`.

Run both. Quote the flake reference — the shell is zsh. Then additionally
assert:

- `systemd.timers` filtered for `restic.*` is empty.
- `systemd.services` filtered for `restic.*` is empty.
- Exactly one `restic-password` warning fires on evaluation.

The claim under test is "enabled but inert." Prove that combination rather
than trust the documents.

### 3. Audit `profiles/backup.nix` as code

This is the highest-value review target: about 600 lines of Nix that
nothing has ever executed on the host. Read it closely, not just skim it.
Check:

- The five preflight conditions. Can any be bypassed?
- The `OnFailure` templated unit. Can it recurse into itself?
- The failure marker. Can anything other than a success clear it?
- `RequiresMountsFor`. Does it guard every unit that touches the disk, or
  only some?
- The cache-directory override. Does it survive the module's own
  `CacheDirectory` setting, or does systemd's own management win?
- The `pg_dumpall` invocation. Does it run as the `postgres` OS user via
  `runuser`, correctly, given that `root` has no identity-map entry?

Ask yourself at each point: what fails silently here, and what fails
loudly? State your answer per item.

### 4. Check the documents against the code and against each other

A prior audit found eight zsh-breaking command lines, a self-contradiction
in `EVIDENCE.md`, and ten drifted `file:line` anchors in `DESIGN.md` — all
reported fixed. Confirm the fixes hold. Then look again for the same
classes of defect, since anchors drift every time a file is edited after
them:

- Any command line that breaks under zsh quoting (unquoted flake refs,
  unescaped globs).
- Any place where two documents assert different facts about the same
  thing.
- Any `file:line` anchor in `DESIGN.md` or `IMPLEMENTATION.md` that no
  longer points at the line it claims to.

One exception: `EVIDENCE.md` §6 deliberately keeps historical
`/mnt/wd_re1` values under a date-stamped paragraph. That is intentional.
Do not report it as stale.

### 5. Assess the honesty of the record

The documents claim nothing is proven that has not been proven. Check that
claim. Look for:

- Any place a backup, snapshot, check, or restore is implied to have
  happened, when it has not.
- Any place "verified" describes something that was only evaluated (for
  example, a Nix module evaluating cleanly is not the same as a unit
  running correctly).
- Any place the WD Green repository's unverified contents are treated as
  known, rather than as unverified.

## Facts carried forward — do not re-measure these

### What exists now

`profiles/backup.nix` declares `nix-meta.backup`. `machines/server.nix`
enables it with `mountPoint = "/mnt/wd_green1"`. `repository` resolves to
`/mnt/wd_green1/restic` and `cacheDir` to `/mnt/wd_green1/restic-cache`. The
profile creates no systemd unit and warns on every evaluation, because
`restic-password` has no encrypted material yet. The backup profile added
no change to the system derivation: `dddd4b1`, the commit that adds and
composes `profiles/backup.nix`, produces the same `toplevel.drvPath` as its
parent `1914dae`. Current trunk carries a different derivation, but for an
unrelated reason — the Mnemonix bump at `d633a35`, another session's work,
not Phase 0. Every Phase 0 commit after `d633a35` is individually
derivation-neutral.

| Commit | Server `toplevel.drvPath` |
|---|---|
| `1914dae` (before any Phase 0 work) | `jgk76qyb7fvlbm0fnjiv5d65h7js1mjs-nixos-system-server-26.11.20260705.d407951.drv` |
| `dddd4b1` (adds `profiles/backup.nix` and composes it) | `jgk76qyb…` — identical to its parent |
| `d633a35` (Mnemonix bump, another session's work, not Phase 0) | `wbjk6lr9jz371zq56ai8q2wjd6ab9nmn-…` |
| current trunk | `wbjk6lr9…` |

No backup, snapshot, check, or restore has ever run.

### The target disk

| Item | Value |
|---|---|
| Device | `/mnt/wd_green1`, `/dev/sda1`, ext4, 1.8T, 59G used, mounted |
| Existing repository | `/mnt/wd_green1/restic`, `root:root 0700`, created 2026-09-28 22:51 with `--insecure-no-password` — password is empty |
| Repository contents | Unverified; completion of the 2026-09-28 backup is unproven; reading it needs root |
| `restic init` needed | No — the repository already exists |
| Disk age | 57,588 power-on hours, 2,175,705 load cycles, clean sector counts |

The user chose this disk over waiting for a WD Re drive, accepting its age,
because a backup on an old disk beats none. A NAS will later hold a second
copy.

### The two remaining blockers (gating items — call these out explicitly)

1. `sudo` needs an interactive password. `sudo -n true` refuses in any
   agent session, so no agent session can do privileged work.
2. No off-host recovery path exists for the repository password. Both SOPS
   recipients derive from keys on the host the backup protects. Losing the
   host locks the backup. A NAS second copy does not fix this — both copies
   answer to the same key.

### The researched recovery design (`DESIGN.md` §3, `IMPLEMENTATION.md` C1b)

- A restic repository has one master key. Every entry under `keys/` wraps
  that same master key, so any key grants identical access, and a
  repository is only as strong as its weakest key.
- The KDF is scrypt. `key add` on this host wrote `N=32768, r=8, p=6`,
  about 32 MiB per guess — calibrated for operator wall-clock time, not
  security margin.
- restic enforces no password strength. A key with password `1234` was
  accepted with exit 0 and no warning.
- Recommendation: a generated 7-word EFF-wordlist passphrase, never fewer
  than 6 words.
- `key add` is O(1) in repository size, about 3.5 seconds regardless of
  size, and takes a non-exclusive lock — safe during a backup. `key remove`
  takes an exclusive lock.
- The passphrase prompt is masked only on a real TTY. With stdin
  redirected, restic reads one unmasked line.
- A wrong password exits 12.

### Known environment traps

- Raw `git` inside a gitman workspace reports a stale and sometimes
  alarming picture, including phantom deletions. Use `gitman status` and
  `gitman doctor` instead. Never hand-repair with raw git.
- `gitman doctor` run from inside a secondary workspace wrongly reports
  "not a colocated jj repo." Run it from the main checkout.
- The permission classifier blocks raw `git` mutations in these repos —
  this is why the `v0.1.1` tag had to be made by the user directly.
- `gitman release` cannot tag a repo with no `pyproject.toml`. That gap is
  filed as the uncommitted gitman issue above.
- The shell is zsh. Every flake reference in a command needs quoting.

### Still open elsewhere (context only — not yours to solve)

- The `pg_dumpall` job ships disabled and unproven; `/var/lib/postgresql`
  deliberately stays inside the plain file backup until proved separately.
- Mnemonix Hindsight application consistency has no solution yet and must
  be settled before Phase E.
- `/mnt/shared` holds about 129 GiB of unadjudicated data, out of scope;
  Phase F stays blocked on it.
- The gitman issue at `63-non-python-repo-versioning` is uncommitted; that
  repo is live, and another session added `64-config-gate-audit` during
  this work.
- Four pruned-but-kept workspace directories sit under
  `nix-meta/.worktrees/`. They are gitignored and harmless.

## Working rules

Route all version control through `gitman`, read-only verbs only:

```bash
cd ~/Documents/Projects/gitman && devenv shell -- bash -c 'cd <repo> && gitman status'
```

Never run `devenv` with `nix-meta` or `nix-secrets` as the working
directory. Never display or record secret material, password values, or
private-key contents. Write in Simplified Technical English. No AI
attribution.

## Required output

Produce a review report with:

1. **A verdict** on whether the work is sound.
2. **Defects found, ranked by severity.**
3. **A plain statement of current state** — what exists, what does not,
   what is proven, what is not.
4. **An ordered list of what to do next**, with the two blockers (`sudo`
   interactive access, off-host recovery) called out as the gating items.
5. For anything you could not verify, say so explicitly and say why. An
   honest "unverified" is worth more than a guess.
6. **End with the single highest-value next action**, stated plainly, with
   your reasoning for why it outranks the alternatives.
