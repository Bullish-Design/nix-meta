# PLAN — nix-meta catch-up (compose the tower/framework machines)

Sequenced plan to bring nix-meta from the pre-tower skeleton (`{wsl,desktop,server}`, `nixos`
hardcoded, 2/8 layer inputs) up to the composition keystone (`{framework,tower}`). nix-meta is the
**integration bottleneck** — the layer repos have advanced; this repo composes them.

Legend: **[NOW]** = doable at eval time today (no physical tower). **[HW]** = blocked on the
physical tower being stood up.

Ground rules for every step: work on a branch (Phase 0, `tower-nix-meta`); `nix flake check` and
`nix eval`/`nix build …toplevel` must pass before commit; route VCS through gitman; do NOT touch the
laptop's boot path until the very last cutover step; no AI-authorship trailers.

---

## Step 0 — Branch + upstream output audit  **[NOW]**

- **Do:** `git checkout -b tower-nix-meta` (via gitman). Then audit what the layer repos actually
  export today — **do not trust the doc gap list; some tower repos are more complete than their docs
  claim.** Run `nix flake show github:Bullish-Design/<repo>` for each of
  `nixos-core, nix-terminal, nix-nvim, nix-desktop, nix-cache, nix-secrets, nix-ci`. Record, per
  repo: does it exist, what `nixosModules`/`homeManagerModules` does it export, is
  `nixos-core.nvidia-compute` present.
- **Deliverables:** an `AUDIT.md` in this project dir mapping each planned import to a real, verified
  output (or flagged missing).
- **Acceptance:** every input planned in Steps 1–6 is backed by a confirmed export, or explicitly
  marked "land upstream first".
- **Risk:** wiring an input to a non-existent module → eval failure. This audit is the guard.

## Step 1 — Extract `profiles/base.nix` + parameterize the username  **[NOW]**

- **Do:** Create `profiles/base.nix` from the shared scaffold currently in `developer.nix`
  (`imports = [ nixos-core.nixosModules.common home-manager.nixosModules.home-manager ]`, flakes /
  experimental-features, `home-manager.useGlobalPkgs/useUserPackages`,
  `programs.home-manager.enable`). Introduce a single `username` source of truth — prefer a NixOS
  option (e.g. `config.tower.username`, defaulted to `andrew` in `base`) over a specialArgs thread,
  so profiles read `config.tower.username`. Sweep every `nixos` hit and reconcile:
  - `profiles/developer.nix:31` `users.nixos` → `users.${config.tower.username}`
  - `profiles/developer.nix:119` `/home/nixos/.nixbuild-logs` → `/home/${username}/.nixbuild-logs`
  - `profiles/developer.nix:127` `baseDir = /home/nixos/code` → `/home/${username}/code`
  - `machines/desktop.nix:9`, `machines/wsl.nix:13` `home-manager.users.nixos` → parameterized
    (or delete with the stub machines in Step 5).
  - Move `system.stateVersion` out of profiles into per-machine files; keep `home.stateVersion`
    per-user.
- **Deliverables:** `profiles/base.nix` (new); edited `developer.nix`; `AGENTS.md` updated to drop
  the "Username is `nixos`: Hardcoded" line (`AGENTS.md:103`) and document the `username` option.
- **Acceptance:** `grep -rn 'nixos' profiles machines` shows no hardcoded user (only repo/module
  names like `nixos-core`); a temporary `framework = mkMachine "framework" [ base developer ]`
  evaluates.
- **Risk:** option-vs-specialArgs choice ripples through every profile — decide once, up front.

## Step 2 — Carry the nixpkgs pins via overlay  **[NOW]**

- **Do:** First **verify** whether `nix-nvim`/`nix-terminal` already pin neovim/zellij upstream
  (from Step 0 audit) — do NOT double-pin. For pins nix-meta must own, add inputs
  `nixpkgs-neovim` (`d2339023`, neovim 0.12), `nixpkgs-zellij`, `nixpkgs-obsidian`,
  `nixpkgs-devenv`, `nixpkgs-claude-code` (revs in KICKOFF §2E), and apply via a `nixpkgs.overlays`
  module injected into `mkMachine`'s module list (mirror the `.dotfiles` overlay pattern).
- **Deliverables:** edited `flake.nix` (pin inputs + overlay module in `mkMachine`).
- **Acceptance:** the pinned `neovim`/`neovim-unwrapped` evaluate to 0.12.x in a machine config;
  `nix flake check` passes.
- **Risk:** double-pinning vs upstream, or a stale rev that fails to fetch. Guarded by Step 0.

## Step 3 — Wire the terminal/desktop layer inputs + rebuild `gui`  **[NOW]**

- **Do:** Add confirmed inputs to `flake.nix` (`github:Bullish-Design/*`, `nixpkgs.follows`):
  `nix-nvim`, `nix-desktop` (and `nixos-hardware` if `framework` uses it). Bring `developer.nix` to
  `.dotfiles` terminal parity (nix-terminal → nix-nvim chain); refresh the `repoman.accounts` repo
  list (drop `nixvim`/`terminal-state`/`devman`, add `nix-nvim/desktop/cache/secrets/ci`). Rebuild
  `profiles/gui.nix` off GNOME/xserver to import `nix-desktop` (niri/noctalia/walker) — **laptop-only**.
- **Deliverables:** edited `flake.nix` (inputs), `developer.nix`, `gui.nix`.
- **Acceptance:** `gui` imports `nix-desktop` and evaluates; `developer` reaches terminal parity.
- **Risk:** niri-on-NVIDIA — keep `gui` importable but UNIMPORTED on tower (framework only).

## Step 4 — Author `framework` machine + config  **[NOW, hardware carry at HW cutover]**

- **Do:** Create `machines/hardware/` dir. Create `machines/framework.nix` (hostname, per-machine
  `system.stateVersion`, Intel/laptop bits, `nixos-hardware` if used, imports
  `machines/hardware/framework.nix`). Stub `machines/hardware/framework.nix` for now (real hardware
  config carried from `~/.dotfiles` only at cutover — Step 9). In `flake.nix` add
  `framework = mkMachine "framework" [ profiles.base profiles.developer profiles.gui ]`.
- **Deliverables:** `machines/framework.nix`, `machines/hardware/framework.nix` (stub), `flake.nix`.
- **Acceptance:** `nix build .#nixosConfigurations.framework.config.system.build.toplevel` evaluates
  (developer + gui, andrew user, pins).
- **Risk:** none at eval; real hardware parity deferred to Step 9.

## Step 5 — Cache + secrets + CI/gpu-compute profiles  **[NOW for what exports; gpu-compute may need upstream]**

- **Do:** Add inputs `nix-cache`, `nix-secrets`, `nix-ci` (confirmed in Step 0). Create
  `profiles/gpu-compute.nix` (nixos-core `nvidia-compute` compute-only driver — **no
  `services.xserver.videoDrivers`, no display stack** — + `nix-cache` client + NVIDIA container
  toolkit + declarative GPU power-limit oneshot with watts as a TODO) and `profiles/ci.nix`
  (`nix-ci` bare-repo + post-receive + act + run-log, act secrets from `nix-secrets`, nixbuild).
  Update `profiles/default.nix` exports to `{ base, developer, gui, gpu-compute, ci }` (decide fate
  of `minimal`).
  - **BLOCKER to verify:** if `nixos-core.nvidia-compute` is not exported (Step 0), land it in the
    nixos-core repo first, bump the input, THEN write `gpu-compute`. Note+skip if blocked.
- **Deliverables:** `profiles/gpu-compute.nix`, `profiles/ci.nix`, edited `default.nix`, `flake.nix`
  inputs, updated `AGENTS.md` (new profile/input set).
- **Acceptance:** `gpu-compute` + `ci` import their modules and evaluate in isolation (against a
  throwaway machine). No display stack pulled into `gpu-compute`.
- **Risk:** missing `nvidia-compute` upstream (guarded by Step 0); accidental display-stack pull-in
  via a transitive nixos-core import.

## Step 6 — Author `tower` machine (eval-only shell) + deploy wiring  **[NOW for eval shell + deploy output; real hw is HW]**

- **Do:** Create `machines/tower.nix` (hostname, per-machine `stateVersion`, `nix-cache` **server**
  enable, `nix-secrets`, tailscale + key-only SSH + tailnet-only firewall; imports
  `machines/hardware/tower.nix`). For now import a **placeholder** `machines/hardware/tower.nix` so
  the config can be authored/eval-shaped, clearly marked "REPLACE with nixos-generate-config output
  from the box". Add `tower = mkMachine "tower" [ base developer gpu-compute ci ]` to `flake.nix`.
  Add `deploy-rs` input + `deploy` output binding `deploy.nodes.{framework,tower}` (tower:
  magic-rollback / auto-rollback). Add a `justfile` (`deploy tower|laptop|all`, `rollback`, `diff`,
  `boot`) over `nixos-rebuild --target-host` + `deploy-rs` reaching tower via tailscale.
- **Deliverables:** `machines/tower.nix`, placeholder `machines/hardware/tower.nix`, `flake.nix`
  (`tower` config + `deploy-rs` input + `deploy` output), `justfile`.
- **Acceptance:** `nix flake check` passes with the placeholder hardware; `deploy` output evaluates
  for both nodes. (Full `.#tower...toplevel` build is expected to remain incomplete until real
  hardware config lands — mark the placeholder clearly.)
- **Risk:** placeholder hardware masking real eval errors — keep it minimal and obviously fake.

## Step 7 — Retire the pre-tower skeleton  **[NOW]**

- **Do:** Once `{framework,tower}` are in place, remove `nixosConfigurations.{wsl,desktop,server}`
  from `flake.nix` and delete/archive `machines/{wsl,desktop,server}.nix`. Update `AGENTS.md`
  examples (`AGENTS.md:56,166,169` reference `wsl`).
- **Deliverables:** edited `flake.nix`, removed machine stubs, updated `AGENTS.md`.
- **Acceptance:** `nix flake show` lists only `{framework,tower}`; `nix flake check` passes.
- **Risk:** low — pure removal after replacements exist.

## Step 8 — Generate tower hardware config + harvest age key  **[HW — blocked on physical tower]**

- **Do:** Confirm the tower runs NixOS (Phase 0 gate — if another distro, this step changes
  materially). On the box: `nixos-generate-config`, copy the real result over the placeholder
  `machines/hardware/tower.nix`. Harvest the tower's age key for `nix-secrets` (sops-nix) and record
  its public key in the secrets config.
- **Deliverables:** real `machines/hardware/tower.nix`; tower age public key registered in
  `nix-secrets`.
- **Acceptance:** `nix build .#nixosConfigurations.tower.config.system.build.toplevel` evaluates a
  headless GPU-compute + CI host (no display stack, nvidia compute driver, container toolkit,
  nix-cache server).
- **Risk:** tower not on NixOS; drives not partitioned as assumed. Gate before starting.

## Step 9 — First bring-up + laptop cutover  **[HW — blocked on physical tower]**

- **Do:** First `nixos-rebuild switch --flake .#tower --target-host tower` over tailscale (verify
  deploy-rs magic-rollback armed FIRST — no console on the headless box). Stand up vLLM container
  on the tailnet; wire tower as the laptop's `nix.buildMachines` target. **Last:** carry the real
  laptop hardware config into `machines/hardware/framework.nix` and cut the laptop over onto the
  `framework` config, retiring the monolithic `~/.dotfiles`.
- **Deliverables:** live tower; live framework; retired `.dotfiles`.
- **Acceptance:** `just deploy tower` switches over tailscale with auto-rollback; vLLM serves on the
  tailnet; laptop boots the `framework` config with no regressions.
- **Risk:** bad switch on a console-less box (mitigated by magic-rollback); laptop regression
  (mitigated by proving parity as a second config before cutover). This is irreversible-ish — do it
  last.

---

## Summary: what to do NOW vs what waits on the tower

- **NOW (eval-time, this session):** Steps 0–7 — branch + audit, `base`, username→`andrew`, pins,
  wire the remaining layer inputs, rebuild `gui`, author `framework`, author `gpu-compute`/`ci`,
  author the `tower` eval-shell + deploy output + justfile, retire the old skeleton. This clears the
  entire integration bottleneck at eval time.
- **BLOCKED on hardware:** Steps 8–9 — real tower hardware config, age-key harvest, first rebuild,
  vLLM, and the laptop cutover. These are the on-box/runtime proof the uniform-cluster blocker
  refers to.
