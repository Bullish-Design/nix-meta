# CONTEXT — phase → file matrix (nix-meta)

Companion to `KICKOFF.md`. Quick lookup of which files each phase touches in
`~/Documents/Projects/nix-meta`. `*` = NEW file/dir. `⚠` = cross-repo or generated dependency.

| Phase | Area | Files in nix-meta | Depends on (other repo) |
|---|---|---|---|
| **1** Base parity | profiles | `profiles/base.nix`*, `profiles/developer.nix`, `profiles/default.nix` | `nix-terminal`→`nix-nvim`⚠ |
| **1** Username | profiles + machines | `profiles/*.nix`, `machines/*.nix`, `AGENTS.md` | — |
| **1** Pins | flake | `flake.nix` (inputs + overlay) | check `nix-nvim`/`nix-terminal` don't already pin |
| **2** Desktop (laptop-only) | profiles | `profiles/gui.nix` (rebuild off GNOME) | `nix-desktop`⚠ |
| **3** Cache + secrets | profiles | `profiles/gpu-compute.nix`* (client), `profiles/ci.nix`* | `nix-cache`⚠, `nix-secrets`⚠ |
| **4** Tower machine | machines + profiles | `machines/tower.nix`*, `machines/hardware/tower.nix`*⚠, `machines/hardware/`*, `profiles/gpu-compute.nix`* | `nixos-core.nvidia-compute`⚠ (NOT exported yet), `nix-cache` server |
| **4** Tower hw | machines | `machines/hardware/tower.nix`*⚠ | **generated on the tower** via `nixos-generate-config` |
| **5** Local CI | profiles | `profiles/ci.nix`* | `nix-ci`⚠, `nixbuild` (reuse), `nix-secrets` |
| **6** Deploy | flake + root | `flake.nix` (`deploy-rs` input + `deploy` output), `justfile`* | `deploy-rs` |
| **6** Laptop cutover | machines | `machines/framework.nix`*, `machines/hardware/framework.nix`* | carry from `~/.dotfiles` (LAST) |
| — | outputs | `flake.nix` — replace `{wsl,desktop,server}` → `{framework,tower}`; retire `machines/{wsl,desktop,server}.nix` | — |

## Profile → import map (target state)

```
base        → nixos-core.common, home-manager (the shared scaffold factored out of developer)
developer   → nix-terminal (→ nix-nvim), nixbuild, repoman   [parity with .dotfiles terminal env]
gui         → nix-desktop (niri/noctalia/walker)             [framework ONLY]
gpu-compute → nixos-core.nvidia-compute, nix-cache(client), container toolkit, GPU power-limit  [tower ONLY, headless]
ci          → nix-ci, nix-secrets, nixbuild                  [tower ONLY]
```

## Machine → composition (target state)

```
framework = [ base developer gui ]                  + hardware/framework.nix
tower     = [ base developer gpu-compute ci ]        + hardware/tower.nix + nix-cache(server) + nix-secrets
```

## Known blockers / verify-before-import

- `nixos-core` currently exports only `{ common, wsl, wsl-upstream }` (see its `flake.nix`).
  `nvidia-compute` / `desktop` / `input-kanata` named in PLAN §4 **do not exist yet** — land them in
  nixos-core, bump the input, then import in `gpu-compute`/`gui`/base.
- `nix-nvim`, `nix-desktop`, `nix-cache`, `nix-secrets`, `nix-ci` are project-new repos — confirm each
  exists + exports the expected module before adding its input.
- `machines/hardware/tower.nix` must be generated on the tower (Phase 4), not authored blind.
- Tower-runs-NixOS assumption must be confirmed (Phase 0) before Phase 4.
```
