# KICKOFF — nix-meta: orchestrate the `framework` + `tower` machines (Tower Dotfiles)

You are starting a FRESH session working in **`~/Documents/Projects/nix-meta`**, the top-level
orchestrator flake of the "Tower Dotfiles" project. This is the **keystone repo**: it composes the
two machines (`framework` laptop, `tower` server) from profiles + the upstream library flakes. Every
other repo in the project (`nixos-core`, `nix-terminal`, `nix-nvim`, `nix-desktop`, `nix-cache`,
`nix-secrets`, `nix-ci`, `home-manager`) is *consumed and composed here*.

> This packet is CONTEXT for the work, not the work. nix-meta already exists as a skeleton
> (`flake.nix` with `mkMachine` + stub `{wsl,desktop,server}`; thin `profiles/` and `machines/`).
> The project supplies the substance. Do NOT scaffold a new repo or restructure the layout — evolve
> what is here.

────────────────────────────────────────────────────────────────────────

## 0. Role & source of truth

- **Master plan (read FULLY first):** `/home/andrew/.dotfiles/.scratch/projects/37-tower-dotfiles/PLAN.md`
  — this repo touches nearly every section. Anchor on **§4** (target architecture / repo map),
  **§5** (machine composition), **§6** (composed CI flow), **all of §8** (phased checklist — this repo
  threads through every phase), **§10/§11** (open items, risks).
- **Decision log:** `/home/andrew/.claude/projects/-home-andrew--dotfiles/memory/tower-dotfiles-project.md`
  — the locked decisions behind every choice below (profiles, deploy-rs, no-reinstall, carry pins).
- **Pin source (READ-ONLY):** `~/.dotfiles/flake.nix` — the nixpkgs pins to carry forward.
- **The existing nix-meta stubs you will evolve** (study, READ-ONLY until you implement):
  `flake.nix`, `AGENTS.md`, `profiles/{default,developer,gui,minimal}.nix`,
  `machines/{wsl,desktop,server}.nix`.

**Phases this repo maps to: 1, 2, 3, 4, 5, 6** (effectively all of §8 after Phase 0). It is the
integration surface — work in the other library repos lands here.

### §5 — machine composition (reproduced verbatim from PLAN)

```nix
framework = mkMachine "framework" [ developer gui ];                 # laptop · Intel · niri
tower     = mkMachine "tower"     [ developer gpu-compute ci ];      # headless · dual-3060
#                                    + nix-cache (server) + nix-secrets + in-place hardware
```

- Username reconciled to **`andrew`** (parameterized; profiles currently hardcode `nixos`).
- Carry `.dotfiles` nixpkgs pins (neovim 0.12, zellij, obsidian, devenv, claude-code) or they regress.
- `system.stateVersion` **per-machine** (do not share one global value across both boxes).

### §6 — composed CI flow (reproduced verbatim — context for the `ci` profile + deploy wiring)

```
LAPTOP   gitman publish ──[publish].verify gate (lint/test)──► git push tower (bare remote, tailscale)
TOWER    post-receive hook
           ├─ run configured per-repo hooks
           ├─ act  (runs .github/workflows/*.yml locally in Docker; GPU-capable)
           ├─ nixbuild  (config-rebuild jobs: nixos-rebuild test + asciinema + JSON result)
           └─ green? ──► forward push to GitHub        ← "local CI gate before GitHub"
CACHE    builds ──► nix-cache (attic) ──► laptop pulls prebuilt
RUN LOG  append JSONL/sqlite   (NOT eventic)
```

The CI *machinery* lives in `nix-ci`/`nix-cache`; nix-meta's job is to **import those modules into the
`ci` profile + tower machine** so the flow has a host to run on.

────────────────────────────────────────────────────────────────────────

## 1. Current shape (what exists today)

`flake.nix`:
- inputs: `nixpkgs` (nixos-unstable), `nixos-core`, `home-manager`, `nix-terminal`.
- `mkMachine name: profileModules` → `lib.nixosSystem` with `specialArgs = { inherit inputs; }`,
  `modules = [ ./machines/<name>.nix ] ++ profileModules`. **Single `system = "x86_64-linux"`.**
- `nixosConfigurations = { wsl, desktop, server }` ← these three get **replaced** by `{ framework, tower }`.

`profiles/`:
- `default.nix` exports `{ developer, minimal, gui }` (each `import ./<n>.nix inputs`).
- `developer.nix` — imports `nixos-core.common` + `home-manager`; sets `system.stateVersion = "25.05"`;
  configures `nix-terminal` (corePackages, git, zsh+aliases, atuin), `nixbuild`, `repoman`.
  **Username hardcoded `nixos`** (`home-manager.users.nixos`, `/home/nixos/...` paths).
- `gui.nix` — currently **GNOME/xserver** (`services.xserver` + gdm + gnome). This is NOT the project's
  desktop; it must be rebuilt to import `nix-desktop` (niri/noctalia/walker) per PLAN §4. Laptop-only.
- `minimal.nix` — thin base; closest thing to the new `base` profile but not it.

`machines/`:
- `wsl.nix`, `desktop.nix`, `server.nix` — all stub overrides, `users.nixos`, empty hardware imports.

`AGENTS.md` constraints to honor/update: "Profiles are composable", "Machines are minimal",
**"Username is `nixos`: Hardcoded"** (this packet removes that constraint), "Order matters — later
profiles override earlier ones."

────────────────────────────────────────────────────────────────────────

## 2. Work items, grouped by area (with target paths)

> All paths below are **inside `~/Documents/Projects/nix-meta`** unless absolute.
> Override semantics: in `mkMachine "x" [ a b c ]`, modules merge as a NixOS module list; **later
> profiles override earlier** (NixOS `mkMerge`/priority rules). Compose accordingly: `base` first,
> capability profiles after, machine file last.

### 2A. `profiles/` — profile set {base · developer · gui · gpu-compute* · ci*}

- **`profiles/base.nix` (NEW).** Extract the shared system + HM scaffold currently buried in
  `developer.nix` (imports of `nixos-core.common` + `home-manager`, flakes/experimental-features, the
  `home-manager.useGlobalPkgs/useUserPackages`, `program.home-manager.enable`). Every machine imports
  `base`. Keep it username-parameterized (§2D).
- **`profiles/developer.nix` (EVOLVE).** Bring to **real parity with `~/.dotfiles` terminal env**
  (Phase 1): shell/zsh + aliases, atuin, tmux/zellij, git config, scripts, the `nix-terminal` →
  `nix-nvim` chain. The current package/alias list is a thin starter — reconcile against
  `~/.dotfiles/home.nix` + `~/.dotfiles/modules/home/*` so the laptop loses nothing at cutover.
  Drop the `base`-level imports once `base.nix` owns them.
- **`profiles/gui.nix` (REBUILD).** Replace the GNOME/xserver stub with an import of
  **`nix-desktop`** (niri · noctalia · walker · workspace-groups, extracted from
  `~/.dotfiles/modules/home/desktop/*` in Phase 2). **Laptop-only** — imported by `framework`, NOT
  `tower`. (PLAN §11: niri-on-NVIDIA risk only returns if `gui` is ever added to the tower; keep it
  importable-but-unimported there.)
- **`profiles/gpu-compute.nix` (NEW — Phase 4).** Headless GPU compute. Imports:
  - `nixos-core`'s **nvidia-compute** module (compute-only driver: kernel module + CUDA,
    `hardware.nvidia.open = true`, **production** driver, **NO `services.xserver.videoDrivers` /
    no display stack**, minimal/zero fbcon VRAM — PLAN §8 Phase 4 + §10 "Headless NVIDIA").
  - **`nix-cache`** *client* options (substituter + trusted key; the *server* half is wired at the
    tower machine, §2C).
  - **NVIDIA container toolkit** (`virtualisation.docker` / `podman` + `nvidia-container-toolkit`,
    `--gpus` passthrough) so vLLM + act-GPU jobs can run.
  - Optional declarative **GPU power-limit** oneshot systemd unit (`nvidia-smi -pm 1 -pl …`,
    keep VRAM clock high) — PLAN §10 research flag; wire the hook, leave the exact watts a TODO.
- **`profiles/ci.nix` (NEW — Phase 5).** Imports **`nix-ci`** (bare repo + `post-receive` + `act` +
  per-repo hooks + run-log). Pulls act secrets from **`nix-secrets`** (sops `--secret-file`). Composes
  `nixbuild` for config-rebuild jobs. Tower-only.
- **`profiles/default.nix` (UPDATE exports).** Export the new set:
  `{ base, developer, gui, gpu-compute, ci }`. Decide the fate of `minimal` (fold into `base` or keep
  as legacy — note the decision; not load-bearing for the two target machines).

> ⚠ Cross-repo dependency (BLOCKER for `gpu-compute`): `nixos-core` today (`flake.nix`) exports ONLY
> `{ common, wsl, wsl-upstream }`. The **`nvidia-compute`** (and `desktop`, `input-kanata`) modules
> named in PLAN §4 **do not exist yet** — they must be added in the `nixos-core` repo first.
> `gpu-compute.nix` cannot import what isn't exported. Sequence: land the nixos-core module, bump the
> input, then write the profile. Note+skip here; flag it in the plan.

### 2B. `machines/` — {framework · tower} + hardware

- **`machines/framework.nix` (NEW).** Laptop. Imports `machines/hardware/framework.nix`; per-machine
  `system.stateVersion`; machine-local overrides only (hostname, Intel/laptop bits, `nixos-hardware`
  if used — cf. `~/.dotfiles/flake.nix` which pulls `nixos-hardware`). Composed as `[ developer gui ]`.
- **`machines/hardware/framework.nix` (NEW).** The laptop's hardware config (carry from
  `~/.dotfiles` hardware config at cutover — Phase 6, NOT now).
- **`machines/tower.nix` (NEW — Phase 4).** Headless server. Imports `machines/hardware/tower.nix`;
  per-machine `system.stateVersion`; hostname; **`nix-cache` server enable** + **`nix-secrets`** +
  in-place hardware; tailscale + key-only SSH + firewall (tailnet-only services). Composed as
  `[ developer gpu-compute ci ]`.
- **`machines/hardware/tower.nix` (NEW — GENERATED, Phase 4).** ⚠ Produced by **`nixos-generate-config`
  run ON the tower itself** (no reinstall; drives already partitioned — PLAN §3/§8 Phase 4). It is
  **not authorable blind** from the laptop — generate on the box, copy the result into the repo.
- Retire `machines/{wsl,desktop,server}.nix` (delete or archive; they back the removed
  `nixosConfigurations`).
- **`machines/hardware/` dir is NEW** — create it.

### 2C. `flake.nix` — inputs + outputs

- **Add inputs** (all `github:Bullish-Design/*`, with `inputs.nixpkgs.follows = "nixpkgs"` where they
  carry a nixpkgs): `nix-nvim`, `nix-desktop`, `nix-cache`, `nix-secrets`, `nix-ci`.
  (`nixos-core`, `nix-terminal`, `home-manager` already present.)
- **Replace** `nixosConfigurations = { wsl, desktop, server }` **with**:
  ```nix
  framework = mkMachine "framework" [ profiles.base profiles.developer profiles.gui ];
  tower     = mkMachine "tower"     [ profiles.base profiles.developer profiles."gpu-compute" profiles.ci ];
  ```
  Tower additionally wires `nix-cache` (**server**) + `nix-secrets` + in-place hardware (via its
  machine file / profile imports — §2B).
- **Carry the pins** (§2E) via overlays threaded through `mkMachine` (mirror the `.dotfiles` overlay
  pattern: a `nixpkgs.overlays` module pinning `neovim`/`neovim-unwrapped` from `nixpkgs-neovim`,
  etc.). `mkMachine` already has a clean module-list seam to inject this.
- Keep `mkMachine` single-arch `x86_64-linux` (both machines are x86_64).
- **deploy-rs**: add the `deploy-rs` input + a `deploy` output (§2F).

### 2D. Username `nixos` → `andrew` (parameterize — Phase 1)

The real config is `andrew`; profiles hardcode `nixos` (AGENTS.md flags this; decision log confirms).
**Parameterize, don't just rename** — expose a `username` so the same profiles serve any host:

- Introduce a single source of truth: either a NixOS **option** (`config.tower.username` or similar,
  defaulted in `base`) or a `username` arg threaded via `mkMachine` → `specialArgs`. Prefer the option
  route so profiles read `config.<ns>.username`.
- Replace every `home-manager.users.nixos`, `/home/nixos/...`, and `users.users.nixos` across
  `profiles/*.nix` and `machines/*.nix` with the parameter. Sweep:
  `grep -rn 'nixos' profiles machines` → reconcile each hit.
- Default to `andrew` for both target machines. Update the `repoman.accounts` repo list + `baseDir`
  (currently `/home/nixos/code`) accordingly — and refresh the repo list to the project's repo set
  (add `nix-nvim`/`nix-desktop`/`nix-cache`/`nix-secrets`/`nix-ci`; `nixvim` is being retired).
- Update `AGENTS.md` to drop the "Username is `nixos`: Hardcoded" constraint.

### 2E. Carry the nixpkgs pins (Phase 1)

From `~/.dotfiles/flake.nix` (READ-ONLY source). These pin specific tools and **regress if dropped**:

| pin input | rev (from .dotfiles) | what it pins |
|---|---|---|
| `nixpkgs-neovim` | `d2339023` | **neovim 0.12.x** (vim.pack support) — overlaid onto `neovim` + `neovim-unwrapped` |
| `nixpkgs-zellij` | `265473c9181f3b18295d634c844bdf7761a18594` | zellij |
| `nixpkgs-obsidian` | `9153c15dafd8458f7142996fe5f75781f75a10fd` | obsidian |
| `nixpkgs-devenv` | `5c9008c2b9e9778cb814afc0a579c35638201cc6` | devenv (`devenv` input `v2.1.2` follows it) |
| `nixpkgs-claude-code` | `331800de5053fcebacf6813adb5db9c9dca22a0c` | claude-code |

- Add each as a flake input; apply via an **overlay module** in `mkMachine`'s module list, mirroring
  the `.dotfiles` pattern (`pkgs-neovim = import inputs.nixpkgs-neovim { system; }; in { neovim = …; }`).
- **Placement decision:** neovim/zellij belong to the terminal layer — confirm whether `nix-nvim` /
  `nix-terminal` already pin these upstream (if so, don't double-pin). If they don't, nix-meta carries
  them. Note where each lands. (The `.dotfiles` `ty` overlay + `niri`/`noctalia` cachix substituters
  are laptop/desktop concerns — fold the cachix substituters into `gui`/`framework` via
  `nix.settings.substituters`.)

### 2F. deploy — deploy-rs + justfile wrapper (Phase 6)

- Add **`deploy-rs`** input; add a `deploy` flake output binding both nodes
  (`deploy.nodes.{framework,tower}`) to their `nixosConfigurations`. Tower is headless → enable
  **auto-rollback / magic-rollback** (PLAN §11: deploy-rs chosen specifically for rollback safety on
  the box with no console).
- Add a **`justfile`** wrapper over `nixos-rebuild --target-host` + `deploy-rs` with recipes:
  `deploy tower|laptop|all`, `rollback`, `diff`, `boot`. Deploy reaches the tower over **tailscale**
  (`--target-host tower`, key-only SSH). (Decision log item 2: "thin justfile/scripts layer".)
- Endgame (out of scope now, note only): GitOps — tower self-redeploys from GitHub via CI.

────────────────────────────────────────────────────────────────────────

## 3. Acceptance criteria (per phase)

- **Phase 1 (base parity + username + pins):** `nix flake check` passes; `developer` profile reaches
  `.dotfiles` terminal parity; `grep -rn 'nixos' profiles machines` shows no hardcoded user (all via
  the `username` parameter); pinned `neovim` evaluates to 0.12.x.
- **Phase 2 (desktop, laptop-only):** `gui` imports `nix-desktop` (niri/noctalia/walker) and evaluates;
  validated as a second config on the laptop without touching its boot path.
- **Phase 3 (cache+secrets):** `nix-cache` client + `nix-secrets` modules import and evaluate within a
  profile; cuda-maintainers cachix substituter present.
- **Phase 4 (tower machine):** `machines/hardware/tower.nix` generated on the box;
  `nix build .#nixosConfigurations.tower.config.system.build.toplevel` **evaluates headless
  GPU-compute + CI** (no display stack, nvidia compute driver, container toolkit, nix-cache server);
  first `nixos-rebuild switch --flake .#tower --target-host tower` lands; vLLM container serves on the
  tailnet; tower wired as the laptop's `nix.buildMachines` target.
- **Phase 5 (CI):** `ci` profile composes `nix-ci` on the tower; the §6 flow has a host (post-receive
  → act → nixbuild → forward-on-green).
- **Phase 6 (deploy + cutover):** `just deploy tower` switches over tailscale with auto-rollback armed;
  `framework` config evaluates `developer + gui`; **laptop cutover** onto `framework` (retire
  monolithic `.dotfiles`) — this is **last**, after parity is proven.

**Top-line gate:** `nix build .#nixosConfigurations.tower…` evaluates a headless GPU-compute + CI host;
`framework` evaluates developer + gui; `just deploy tower` switches over tailscale; laptop cuts over
onto the `framework` config.

────────────────────────────────────────────────────────────────────────

## 4. Dependencies & integration

This is where **everything composes**. nix-meta consumes ALL libraries:

| Input | Provides | Consumed by |
|---|---|---|
| `nixos-core` | `common`, **`nvidia-compute`\***, `desktop`\*, `input-kanata`\* | base, gpu-compute, gui |
| `nix-terminal` | terminal HM env → `nix-nvim` | developer |
| `nix-nvim`\* | HM nvim (loci, promoted from `.dotfiles/nvim`) | developer (via nix-terminal) |
| `nix-desktop`\* | niri/noctalia/walker HM env | gui (laptop-only) |
| `nix-cache`\* | attic server/client + buildMachines + post-build-hook | gpu-compute (client), tower machine (server) |
| `nix-secrets`\* | sops-nix wrapper | ci, tower machine |
| `nix-ci`\* | bare-repo + post-receive + act + run-log | ci |
| `home-manager` | HM-as-NixOS-module | base |
| `deploy-rs` | remote switch + rollback | flake `deploy` output |

`* = created/changed by this project; may not exist or export the named module yet — verify the
upstream output before importing (see the nixos-core BLOCKER in §2A).`

**Ordering / override semantics:** module list order in `mkMachine` is `base → developer → capability
profiles → machine file`. Later entries override earlier (NixOS priority). Capability profiles
(`gpu-compute`, `ci`, `gui`) should set only what they own; machine files hold the final per-host word
(hostname, hardware, stateVersion).

────────────────────────────────────────────────────────────────────────

## 5. Open items (from PLAN §10/§11) relevant here

- **vLLM stand-up is a tower *runtime* concern, wired here (Phase 4):** container (NVIDIA toolkit,
  TP=2 over PCIe, OpenAI API on tailnet). The container/service definition lands via `gpu-compute` or
  the tower machine. Quantization (AWQ/GPTQ to fit 24 GB) + exact model = runtime detail, note as TODO.
- **Confirm the tower runs NixOS (Phase 0) BEFORE Phase 4.** The whole "no-reinstall /
  `nixos-generate-config` in place" path assumes it. If it's another distro, Phase 4 changes
  materially. Note+gate.
- **deploy-rs auto-rollback on the headless box** is a hard requirement, not a nicety — there's no
  console to recover from a bad switch (§11). Verify magic-rollback before the first real `deploy tower`.
- **Laptop stays on `.dotfiles` until cutover (Phase 6, last).** Nothing in this repo touches the
  laptop's boot path until parity is proven. Work on a branch (Phase 0).
- **GPU power-limiting** (§10): wire the declarative oneshot hook in `gpu-compute`; leave the watts a
  tunable TODO (~70% ≈ 120–130 W, keep VRAM clock high).
- **act + GPU passthrough** flags (§10) and **Playwright-on-NixOS** browser env (§10) are runtime
  details surfaced by `nix-ci`; nix-meta only needs to expose the container toolkit + GPU access.

────────────────────────────────────────────────────────────────────────

## 6. Guardrails for the implementing session

- Work on a **branch** (Phase 0); never touch the laptop's boot path until Phase 6 cutover.
- **Do not** carry pins blindly — check whether `nix-nvim`/`nix-terminal` already pin neovim/zellij
  upstream before double-pinning in nix-meta (§2E).
- **`machines/hardware/tower.nix` is generated on the tower**, not hand-written from the laptop.
- A library module you need may not exist/export yet (esp. `nixos-core.nvidia-compute`) — land it in
  the library repo first, bump the input, then import. Note+skip+continue on any such gap.
- Update `AGENTS.md` alongside the code (username constraint, new profile/machine set, new inputs).
- No AI-authorship trailers in any commit, doc, or comment.

## 7. First moves

1. Read PLAN.md fully, then the decision log, then this packet's §1–§2.
2. `git checkout -b tower-nix-meta` (Phase 0).
3. Audit upstream outputs: `nix flake show github:Bullish-Design/nixos-core` (and each library) to see
   what actually exports today vs what §4 names. Record the gaps.
4. Start Phase 1: factor `base.nix`, parameterize `username`, carry pins, bring `developer` to parity.
5. Present the per-phase plan for approval before wiring `nixosConfigurations.{framework,tower}`.
