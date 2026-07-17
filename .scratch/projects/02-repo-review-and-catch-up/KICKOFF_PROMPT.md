# KICKOFF PROMPT — nix-meta catch-up (paste into a fresh session from the repo root)

You are starting a fresh session in **`~/Documents/Projects/nix-meta`**, the top-level
orchestration flake and **keystone** of the 9-repo "tower" initiative that decomposes the monolithic
`~/.dotfiles` into layered Nix module flakes. Your job in this repo is **composition, not module
authoring**: wire the layer flakes as inputs and assemble them into concrete `nixosConfigurations`
for two machines — a **`framework`** laptop (Intel · niri) and a headless dual-3060 Xeon
**`tower`** compute/CI box.

## Current state (verified — this repo is the integration bottleneck)

nix-meta is still the **pre-tower skeleton** and is the least-advanced tower repo relative to its
target. Concretely, against the actual `flake.nix`:

- **Inputs: only 2 of 8 layer flakes wired** — `nixos-core` and `nix-terminal` (plus `home-manager`).
  Missing: `nix-nvim`, `nix-desktop`, `nix-cache`, `nix-secrets`, `nix-ci`, `deploy-rs`, and all the
  `.dotfiles` nixpkgs pins.
- **Machine configs: neither target exists.** `nixosConfigurations = { wsl, desktop, server }` (old
  skeleton names). No `framework`, no `tower`, no `machines/hardware/` dir.
- **Username still hardcoded `nixos`** across `profiles/developer.nix` (`users.nixos`,
  `/home/nixos/...`), `machines/{desktop,wsl}.nix`, and `AGENTS.md:103`. Target is a parameterized
  `andrew`.
- **Profiles are pre-tower:** exports `{ developer, minimal, gui }` (need `{ base, developer, gui,
  gpu-compute, ci }`); `gui` is a GNOME/xserver stub (should be `nix-desktop`/niri).

Full detail: read `OVERVIEW.md` and `PLAN.md` next to this file
(`.scratch/projects/02-repo-review-and-catch-up/`). The original effort packet is in
`.scratch/projects/01-tower-nix-meta/{KICKOFF.md,CONTEXT.md}`; the master plan is
`~/.dotfiles/.scratch/projects/37-tower-dotfiles/PLAN.md` (READ-ONLY pin source: `~/.dotfiles/flake.nix`).

## Pointers

- `flake.nix` — the composition seam (`mkMachine`, `inputs`, `nixosConfigurations`). Where inputs and
  machine configs get wired.
- `profiles/` — `default.nix` (exports), `developer.nix` (holds the base scaffold to extract),
  `gui.nix` (GNOME stub to rebuild), `minimal.nix`.
- `machines/` — stub `{wsl,desktop,server}.nix` to retire; you will add `framework.nix`, `tower.nix`,
  and a new `hardware/` dir.
- `AGENTS.md` — repo conventions; update the "Username is `nixos`: Hardcoded" line when you
  parameterize.
- `PLAN.md` (this dir) — the sequenced Steps 0–9, with `[NOW]` vs `[HW]` gating.

## Your first task

Do **Step 0 then Step 1** from `PLAN.md`:

1. Branch: `tower-nix-meta` (via gitman).
2. **Audit upstream outputs** — run `nix flake show github:Bullish-Design/<repo>` for each layer repo
   and record what actually exports. Do NOT trust the docs' gap list: some tower repos turned out
   more complete than their docs claimed, so verify real outputs (especially whether
   `nixos-core.nvidia-compute` exists). Write findings to `AUDIT.md` in this project dir.
3. Extract `profiles/base.nix` from the shared scaffold in `developer.nix`, and **parameterize the
   username** to `andrew` (prefer a NixOS option like `config.tower.username` defaulted in `base`,
   not a blind rename). Sweep `grep -rn 'nixos' profiles machines` and reconcile every hit; move
   `system.stateVersion` to per-machine.

Then present the per-step plan (inputs + machine configs) for approval **before** wiring
`nixosConfigurations.{framework,tower}`.

## Conventions (hard rules)

- This is a **Nix flake repo** — validate before every commit: `nix flake check` and
  `nix eval`/`nix build .#nixosConfigurations.<name>.config.system.build.toplevel` must pass. Never
  commit a config that doesn't evaluate.
- Route **all** version control through **gitman** (jj + colocated git) — never raw jj/git. Branch
  (lane) first off the default branch. Commit as you go; do NOT push without an explicit ask.
- **Never touch the laptop's boot path.** The laptop stays on `~/.dotfiles` until the final cutover
  (PLAN Step 9). Everything before that is eval-only.
- The `tower` machine's real hardware config is **generated on the box** (`nixos-generate-config`),
  not authored blind — use a clearly-marked placeholder until the physical tower is up (PLAN Steps
  8–9 are hardware-blocked).
- A library module you need may not exist/export yet (esp. `nixos-core.nvidia-compute`) — land it
  upstream first, bump the input, then import. Note+skip+continue on any such gap.
- Update `AGENTS.md` alongside the code (username, new profiles, new inputs).
- No AI-authorship trailers in any commit, PR, doc, or comment.

Work through `PLAN.md` in order; Steps 0–7 are doable now at eval time, Steps 8–9 wait on the
physical tower.
