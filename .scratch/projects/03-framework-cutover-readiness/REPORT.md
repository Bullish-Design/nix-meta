# Framework cutover readiness report

**Date:** 2026-10-07  
**Target:** switch the Framework laptop from the active `~/.dotfiles` NixOS flake to `nix-meta`’s `nixosConfigurations.framework`.

## Executive summary

`nix-meta` already defines the Framework system and carries most of the NixOS and graphical-desktop foundation. It is **not yet ready for a clean cutover**. The remaining work is concentrated in profile composition, terminal runtime dependencies, personal Home Manager settings, and making the flake inputs fetchable from the Framework.

The intended migration decisions used in this report are:

- Fan-control parity is out of scope.
- The editor-command difference is out of scope.
- Losing tmux is acceptable; Zellij is the preferred terminal multiplexer.
- Project-specific compilers, language runtimes, browser drivers, and similar tools belong in each project’s `devenv`, not in the laptop-wide system package set.
- Framework should include the developer profile. `gh` should remain globally available.
- Git, Solaar, and the desired Zsh configuration still need to be represented declaratively.
- Framework Home Manager state version should stay at `23.11`, matching the active dotfiles configuration and the laptop’s original install.

The most important implementation gates are:

1. Add the developer profile without conflicting with Framework’s attach-only Shellij setting, and keep project toolchains out of the global package list.
2. Provide Kitty and Zellij as working desktop runtimes, and remove or replace the tmux assumptions in the enabled workspace-groups feature.
3. Migrate Git, Zsh, and Solaar settings into the appropriate Home Manager modules.
4. Make all flake inputs resolvable on the Framework, then refresh and validate the committed lock file.

This report is based on static inspection of nix-meta and the active `~/.dotfiles` configuration. No build, switch, or test was run while preparing it.

## Current Framework composition

The Framework output currently composes:

```nix
[ profiles.minimal profiles.terminal profiles.graphical profiles.desktop ]
```

The corresponding module is `machines/framework.nix`; the output is declared in `flake.nix`. This gives the laptop the NixOS base, nix-terminal Home Manager module, Niri/Noctalia graphical stack, nix-apps bundles, and current Solaar package/service. The developer profile is **not** selected.

The active dotfiles configuration at `~/.dotfiles/flake.nix` also defines a Framework NixOS output. It remains the source of truth for user-specific settings and packages during this migration. The existing `nix-meta` `system.stateVersion` is already `23.11`; the Home Manager state version is different because the shared profiles default it to `25.05`.

## Required work

### 1. Compose the developer profile and keep global packages intentional

**Files:** `flake.nix`, `profiles/developer.nix`, `machines/framework.nix`.

- Add `profiles.developer` to the Framework composition. This profile provides nixbuild, repoman, Shellij, and a developer package list.
- `gh` is **already** in `profiles/developer.nix`’s default package list, so no duplicate package declaration is needed. Selecting the profile makes it available to Framework.
- The profile currently also installs `nodejs` and `python3`. Remove those from the global default if the project-devenv policy is to keep language runtimes project-local. Keep the `devenv` executable itself available so projects can enter their declared environments; keep `gh` global as requested.
- Keep `gcc`, `cargo`, Go, `uv`, Nim/Nimble, Node.js, Python environments and packages, Playwright/browser drivers, tree-sitter, and similar project tools out of the Framework system package list. Add each to a project’s `devenv.nix`/`devenv.yaml` only where that project needs it. The Framework’s existing ambient CLI utilities in `machines/framework.nix` can remain; they are not project language toolchains.
- Review whether the developer profile’s nixbuild and repoman modules/settings are intended on the Framework. Both are enabled by default when the profile is selected. The repoman default project root matches `~/Documents/Projects`; nixbuild logs default to `~/.nixbuild-logs`.

**Shellij conflict to resolve:** `machines/framework.nix` sets `programs.shellij.projectsRoot = null` for the attach-only laptop client. `profiles/developer.nix` sets the same option to `~/Documents/Projects`. Combining the modules can produce competing definitions. Preserve the Framework’s attach-only behavior by making the root configurable in the developer profile, or by adding an explicit Framework override with appropriate module priority. Do not leave two equal-priority values.

### 2. Finish the Kitty and Zellij runtime path

**Files:** `profiles/desktop.nix` or a small Home Manager module, `machines/framework.nix`, and potentially the `nix-desktop` module source.

#### Kitty

- The Framework sets `TERMINAL=kitty`, but the selected Framework profiles do not configure Kitty. The dormant `profiles/gui.nix` contains a Kitty system package but is not selected, and it is an old GNOME profile rather than the current Niri desktop module.
- Add Kitty to the active desktop/Home Manager composition and carry over the settings from `~/.dotfiles/kitty/default.nix` that remain desired: LiquidCarbon theme, Iosevka Nerd Mono, font/window settings, and copy/paste bindings.
- Nix-desktop’s Niri binds call `kitty-smart`; the active dotfiles provide that command in `scripts/shell/scripts.nix`. Nix-meta must either package the desired script in the Framework user environment or change the binding to a command the selected modules actually provide.
- The dotfiles’ `TERM=kitty` system variable may be unnecessary once Kitty is configured because Kitty sets its terminal type for child processes. Avoid retaining a global Kitty-specific `TERM` setting unless it is intentionally needed outside Kitty.

#### Zellij, without carrying tmux forward

- Add a user-available Zellij package for Framework and provide the Zellij configuration/desktop entry required by the chosen UI. The current nix-desktop sidebar invokes `kitty ... zellij` and expects `~/.config/zellij/sidebar-config.kdl`; the dotfiles currently create that file. The desktop launcher configuration also refers to `zellij-terminal.desktop`.
- Choose which dotfiles Zellij settings to retain: the default layout/theme/keybindings, terminal/sidebar layouts, and any wrappers such as `zellij-terminal` or `znv`. The Zellij package can use the Framework’s selected nixpkgs unless a specific pin is deliberately required.
- Do not migrate tmux configuration or tmuxp workspaces as a parity requirement.
- **Workspace-groups dependency:** the currently enabled nix-desktop `workspace-groups` scripts and group data use tmux sessions (`tmux-session`, `tmux has-session`, and related commands). With tmux intentionally omitted, either:
  1. update nix-desktop’s workspace-groups implementation and schema to use Zellij sessions; or
  2. disable that component and accept losing its named-workspace/group-management behavior.

  Installing Zellij alone will not make the current tmux-backed workspace-group scripts work. Treat this as a cutover gate if `workspace-groups.enable = true` remains enabled.

### 3. Declare the personal Git configuration

**Likely owners:** `profiles/developer.nix` for shared developer hosts, or a Framework-only Home Manager module if the settings should not apply to the server.

- The terminal profile currently sets `programs.nix-terminal.enableGit = false` to preserve a hand-maintained `~/.gitconfig`. For a declarative cutover, define one clear Git owner and update that comment/setting so the intended ownership is not contradictory.
- Reproduce the active dotfiles Git settings: user identity, `main` as the initial branch, `push.autoSetupRemote`, pull without rebase, `zdiff3` conflict style, and the `gh auth git-credential` helper.
- `gh` must be installed wherever that helper is configured. Including the developer profile provides it.
- Enable/configure Delta integration as in `~/.dotfiles/git/default.nix`; `delta` is already present as an executable in the Framework package list, but its Home Manager integration/settings are not represented by the current nix-meta profile.
- Decide ownership scope before placing this in `profiles/developer.nix`: that profile is also selected by the server. If Git identity/configuration should be laptop-only, put it in a Framework-specific module instead.

### 4. Migrate the desired Zsh setup

**Likely owner:** `profiles/terminal.nix` if the same interactive shell should apply to all terminal-profile hosts; otherwise a Framework-only Home Manager module.

Nix-meta already enables Zsh, completion, autosuggestions, syntax highlighting, Atuin, and a Starship prompt. The active dotfiles add a custom Oh My Zsh `devprompt` theme, aliases, larger history settings, and hooks for command timing, terminal titles, and comment-history capture. To preserve those behaviors:

- Configure the desired prompt and aliases rather than relying on the current Starship defaults.
- Port the custom Zsh initialization/hooks that are still wanted. Confirm the selected nix-terminal module’s theme support actually enables the desired Oh My Zsh behavior; if it only installs the theme file, use a small Home Manager module or extend the owning nix-terminal module.
- Decide whether to retain dotfiles’ zoxide integration (`cd` → `z`) and Atuin settings. Atuin exists in both configurations, but the dotfiles enable the daemon and automatic workspace-filtered sync while nix-meta disables automatic sync and uses different search/filter settings.
- Preserve the optional `.secrets.env` sourcing only if still wanted; do not put secret values in nix-meta.

### 5. Complete Solaar’s configuration

**File:** `profiles/desktop.nix` (or a dedicated desktop component).

Solaar is already installed and started as a user service. Bring over the missing details from `~/.dotfiles/modules/home/desktop/solaar/default.nix`:

- Manage `~/.config/solaar/config.yaml` with the installed package version.
- Add `After = [ "graphical-session.target" ]` to the unit.
- Add `RestartSec = 3` while keeping the existing graphical-session relationship, restart policy, and `ExecStart`.

### 6. Set the Framework Home Manager state version

**File:** `machines/framework.nix`.

Set `home-manager.users.andrew.home.stateVersion` to `23.11` (preferably using the existing username binding). The terminal, desktop, and developer profiles use `mkDefault "25.05"`; a normal machine-level definition should override those defaults for Framework. Keep `system.stateVersion = "23.11"` as it is.

Home Manager state version selects compatibility defaults; it does not pin the Home Manager source revision. The 24.05 and 24.11 release notes list no state-version changes; 25.05 changes Git signing-format defaults. The reviewed dotfiles do not configure Git signing, so this specific change has no identified current effect, but retaining 23.11 preserves the laptop’s established Home Manager state. See the [Home Manager state-version description](https://home-manager.dev/manual/unstable/options/home-manager/home.html) and [25.05 release notes](https://home-manager.dev/manual/unstable/release-notes/rl-2505.html).

### 7. Make flake inputs portable and lock the selected sources

**File:** `flake.nix` and `flake.lock`.

- `flake.nix` has local `git+file:` inputs for nix-paseo, shellij, and structured-agents under `/home/andrew/Documents/Projects`. Those absolute paths are tied to this checkout layout. At minimum, Framework’s required Shellij input must be portable; convert it to a GitHub Git URL with a committed lock revision. Convert the other local inputs too, or otherwise prove their server-only use does not prevent Framework evaluation on the laptop.
- The flake also declares private SSH inputs such as nix-secrets and zelligate. Confirm that evaluating the Framework output on the laptop can resolve the declared inputs with available credentials. If server-only inputs impose an unnecessary laptop fetch/auth requirement, consider separating the server flake boundary rather than weakening access controls.
- Review the pinned nix-desktop migration branch and its wallpaper asset. The source comment says that branch carries an asset not present on main; retain a usable pinned source or land that migration on a stable branch before cutover.
- Refresh and commit `flake.lock` only after the desired refs and portable input URLs are chosen. The earlier latest-source review used a temporary lock; it did not update the tracked nix-meta lock. Do not treat that temporary lock as the cutover lock.

## Cutover checklist and acceptance criteria

Before switching the laptop:

1. Framework profile composition includes `developer`, and its Shellij project-root behavior is unambiguous.
2. Global developer packages are limited to the intended shared tools (`gh`, `devenv`, and any explicitly approved utilities); project toolchains are declared in project devenvs.
3. Kitty launches from the intended Niri keybind and has its managed configuration. Zellij launches from the sidebar/terminal entry and has every config file those launchers expect.
4. The enabled workspace-groups feature has no tmux runtime dependency, or is intentionally disabled.
5. Git, Zsh, Solaar, and Home Manager state version have the intended declarative settings.
6. The Framework flake evaluates using portable, locked inputs on the target laptop.
7. Run the repository’s flake/evaluation checks and a Framework dry build from the finalized checkout. Inspect the resulting system and Home Manager closures for missing commands and file collisions before activation. `home-manager.backupFileExtension = "hm-backup"` is already configured as a guard for first activation; review any generated backups rather than assuming they are disposable.
8. Keep the current working NixOS generation available until the new Framework generation has booted and the desktop, network, storage, and user session have been checked.

The report does not prescribe a system switch. A successful evaluation and dry build, plus resolution of the tmux-backed workspace-groups behavior, are the minimum readiness gates before activation.

## Source files reviewed

- `flake.nix`, `flake.lock`
- `machines/framework.nix`, `machines/hardware/framework.nix`
- `profiles/{default,minimal,terminal,developer,graphical,desktop,gui}.nix`
- `~/.dotfiles/flake.nix`, `configuration.nix`, `home.nix`
- `~/.dotfiles/git/default.nix`, `shell/{zsh,atuin,zoxide}.nix`, `kitty/default.nix`, `zellij/default.nix`, `tmux/default.nix`
- `~/.dotfiles/modules/home/desktop/solaar/default.nix`
- Latest archived nix-terminal, nix-desktop, and nix-apps sources used in the preceding dependency review
