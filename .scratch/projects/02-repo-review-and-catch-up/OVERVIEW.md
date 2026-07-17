# OVERVIEW — nix-meta: the composition keystone (repo review + catch-up)

Companion project dir: `.scratch/projects/02-repo-review-and-catch-up/`.
Source of truth for the effort: `.scratch/projects/01-tower-nix-meta/{KICKOFF.md,CONTEXT.md}`
and the master plan `~/.dotfiles/.scratch/projects/37-tower-dotfiles/PLAN.md`.

## What nix-meta IS

nix-meta is the **keystone** of the 9-repo "tower" initiative that decomposes the
monolithic `~/.dotfiles` into layered Nix module flakes. It is the top-level
**orchestration flake**: it does not itself own much module logic — its job is to
**compose** the layer flakes (`nixos-core`, `nix-terminal`, `nix-nvim`, `nix-cache`,
`nix-secrets`, `nix-ci`, `nix-desktop` + `home-manager`, `deploy-rs`) into concrete
`nixosConfigurations` for **two real machines**:

- **`framework`** — Framework laptop · Intel · niri desktop · composed `[ base developer gui ]`.
- **`tower`** — headless dual-3060 Xeon compute/CI box · composed `[ base developer gpu-compute ci ]`.

The composition seam is `mkMachine` in `flake.nix`:
`mkMachine name profileModules → lib.nixosSystem { modules = [ ./machines/<name>.nix ] ++ profileModules; }`,
single-arch `x86_64-linux`, `specialArgs = { inherit inputs; }`. Override order is
`base → developer → capability profiles → machine file` (later wins, NixOS priority).

## Desired final concept (target state, from KICKOFF §2 / CONTEXT)

Profile → import map:

```
base        → nixos-core.common, home-manager           (shared scaffold, username-parameterized)
developer   → nix-terminal (→ nix-nvim), nixbuild, repoman   [.dotfiles terminal parity]
gui         → nix-desktop (niri/noctalia/walker)             [framework ONLY]
gpu-compute → nixos-core.nvidia-compute, nix-cache(client), NVIDIA container toolkit, GPU power-limit  [tower ONLY, headless]
ci          → nix-ci, nix-secrets, nixbuild                  [tower ONLY]
```

Machine → composition:

```
framework = [ base developer gui ]           + machines/hardware/framework.nix
tower     = [ base developer gpu-compute ci ] + machines/hardware/tower.nix + nix-cache(server) + nix-secrets
```

Plus: `username` parameterized to **`andrew`** (option or specialArgs, not a blind rename);
per-machine `system.stateVersion`; `.dotfiles` nixpkgs pins carried via overlay through
`mkMachine`; `deploy` flake output binding both nodes (tower with magic-rollback); a `justfile`
wrapper over `nixos-rebuild --target-host` + `deploy-rs` reaching the tower over tailscale.

## Where it is NOW (verified against the actual repo, 2026-07-01)

Reviewed `flake.nix`, `profiles/{default,developer,minimal,gui}.nix`,
`machines/{wsl,desktop,server}.nix`, `AGENTS.md`. **The prior "LAGGING" flag is correct** — this
repo is still the pre-tower skeleton; it is the *least* advanced of the tower repos relative to
its target. Concrete findings:

### Inputs — only 2 of the 8 layer flakes are wired

`flake.nix` `inputs` (lines 4–18) contains exactly:
`nixpkgs`, **`nixos-core`**, `home-manager`, **`nix-terminal`**.

| Layer flake | Wired as input? | Evidence |
|---|---|---|
| `nixos-core`   | **YES** | `flake.nix:7` |
| `nix-terminal` | **YES** | `flake.nix:14–17` |
| `home-manager` | YES (support) | `flake.nix:9–12` |
| `nix-nvim`     | **NO** | absent from `inputs` |
| `nix-cache`    | **NO** | absent |
| `nix-secrets`  | **NO** | absent |
| `nix-ci`       | **NO** | absent |
| `nix-desktop`  | **NO** | absent |
| `deploy-rs`    | **NO** | absent (no `deploy` output either) |
| nixpkgs pins (`nixpkgs-neovim/zellij/obsidian/devenv/claude-code`) | **NO** | absent; no overlay module in `mkMachine` |

### Machine configs — neither target machine exists

`flake.nix:36–40` declares `nixosConfigurations = { wsl, desktop, server }` — the **old pre-tower
skeleton names**. There is **no `framework` and no `tower`** config. `machines/` holds only
`wsl.nix`, `desktop.nix`, `server.nix` (all thin stubs with empty hardware imports). There is
**no `machines/hardware/` directory** and no `machines/framework.nix` / `machines/tower.nix`.

### Username — still hardcoded `nixos`, NOT parameterized

`grep -rn 'nixos' profiles machines` confirms the hardcode across the composed configs:
- `profiles/developer.nix:31` — `users.nixos = { ... }:`
- `profiles/developer.nix:119` — `outputDir = "/home/nixos/.nixbuild-logs"`
- `profiles/developer.nix:127` — `baseDir = "/home/nixos/code"`
- `machines/desktop.nix:9` and `machines/wsl.nix:13` — `home-manager.users.nixos = ...`
- `AGENTS.md:103` — still states **"Username is `nixos`: Hardcoded in current profiles"** and
  `AGENTS.md:87` documents `home-manager.users.nixos`.

No `username` option, no `specialArgs.username`, no `config.<ns>.username`. Default user is `nixos`,
not `andrew`.

### Profiles — pre-tower shapes; the tower profile set does not exist

- `profiles/default.nix` exports `{ developer, minimal, gui }` — **not** the target
  `{ base, developer, gui, gpu-compute, ci }`. No `base`, `gpu-compute`, or `ci`.
- `profiles/developer.nix` still carries the base-level scaffold (imports `nixos-core.common` +
  `home-manager`, sets flakes + `system.stateVersion = "25.05"`) that should be extracted into
  `base.nix`. Its `repoman.accounts` repo list (lines ~131–141) is stale: lists `nixvim`,
  `terminal-state`, `devman` and omits the new tower repos (`nix-nvim/desktop/cache/secrets/ci`).
- `profiles/gui.nix` is a **GNOME/xserver** stub (`services.xserver` + gdm + gnome), NOT the
  project's niri/noctalia/walker `nix-desktop` desktop. Must be rebuilt.
- `profiles/minimal.nix` is a thin base — close to the intended `base` but not it, and still
  hardcodes `system.stateVersion` globally rather than per-machine.

### stateVersion is shared, not per-machine

`system.stateVersion = "25.05"` is set inside `profiles/developer.nix:14` and
`profiles/minimal.nix:12` (shared across every consumer), contrary to the target of a
per-machine value.

### Runtime / on-box proof — undone (the uniform cluster blocker)

`machines/hardware/tower.nix` must be produced by `nixos-generate-config` **run on the tower
itself**, and the age key harvested + first `nixos-rebuild switch --flake .#tower` performed on the
box. The physical tower is **not stood up yet**, so none of this — nor any evaluation of
`.#nixosConfigurations.tower` — has happened. This is eval-blocked for the tower target and
hardware-blocked for bring-up.

## Concept-vs-reality gap table

| Concept (target)                                   | Reality now                                              | Evidence (real file/attr)                                  | Doable at eval-time now? |
|----------------------------------------------------|----------------------------------------------------------|------------------------------------------------------------|--------------------------|
| 8 layer flakes wired as inputs                     | Only `nixos-core` + `nix-terminal` wired (2/8)           | `flake.nix:4–18`                                            | YES (for repos that exist + export) |
| nixpkgs pins carried via overlay                   | No pin inputs, no overlay in `mkMachine`                 | `flake.nix:4–18`, `mkMachine` at `flake.nix:29–33`         | YES |
| `nixosConfigurations.{framework,tower}`            | `{ wsl, desktop, server }`                               | `flake.nix:36–40`                                          | framework: YES · tower: eval-blocked on hw config |
| `profiles/{base,gpu-compute,ci}` exist             | Only `{ developer, minimal, gui }`                       | `profiles/default.nix`                                     | base/ci authorable; gpu-compute blocked on nixos-core.nvidia-compute |
| `gui` = nix-desktop (niri)                          | `gui` = GNOME/xserver stub                               | `profiles/gui.nix`                                         | YES once `nix-desktop` input exists |
| Username = `andrew`, parameterized                 | Hardcoded `nixos` throughout                             | `developer.nix:31,119,127`; `desktop.nix:9`; `wsl.nix:13`; `AGENTS.md:103` | YES |
| Per-machine `system.stateVersion`                  | Shared `25.05` in profiles                               | `developer.nix:14`, `minimal.nix:12`                       | YES |
| `machines/hardware/{tower,framework}.nix`          | No `machines/hardware/` dir at all                       | `machines/` listing                                        | tower: BLOCKED (generate on box); framework: at cutover |
| `deploy` output + `justfile` (deploy-rs)           | No `deploy-rs` input, no `deploy` output, no `justfile`  | `flake.nix` outputs (`flake.nix:35–41`)                    | wiring YES; real switch BLOCKED on hw |
| On-box bring-up (hw config, age key, rebuild)      | Not started — physical tower not stood up                | —                                                          | NO (blocked on hardware) |

## Cross-repo blockers to verify before importing (from KICKOFF §2A / CONTEXT)

- `nixos-core` historically exports only `{ common, wsl, wsl-upstream }`; the `nvidia-compute`
  (and `desktop`, `input-kanata`) modules named for `gpu-compute`/`gui` **may not exist/export yet**.
  Run `nix flake show github:Bullish-Design/nixos-core` and each library before wiring its input —
  **some tower repos turned out more complete than their docs claimed, so verify actual outputs, do
  not trust the doc gap list blindly.** Land the module in the library repo first if missing, bump
  the input, then import.
- `nix-nvim`, `nix-desktop`, `nix-cache`, `nix-secrets`, `nix-ci` are project-new repos — confirm
  each exists and exports the expected module before adding its input.

## Bottom line

nix-meta is the **integration bottleneck**: it is wired **2/8** on layer inputs, has **neither**
target machine config, and **still hardcodes the `nixos` username**. The bulk of the layer work
landed in the sibling repos has **not yet been composed here**. Most of the catch-up (inputs,
username parameterization, `base`/`ci`/`gui` profiles, `framework` machine, pins, deploy wiring) is
**doable now at eval time**; only the `tower` machine's generated hardware config and the runtime
bring-up are gated on the physical box.
