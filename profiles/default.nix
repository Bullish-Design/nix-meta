inputs:
{
  minimal = import ./minimal.nix inputs;

  # Additive user-level developer workflow. It expects the base tier for the
  # username SSOT and composes with (but does not reconfigure) `terminal`.
  developer = import ./developer.nix inputs;

  # Headless NVIDIA CUDA layer (Phase C) — stacked on top of `minimal`.
  gpu-compute = import ./gpu-compute.nix inputs;

  # Agent tooling (Claude Code) for on-box SSH work — stacked on `minimal`.
  agent = import ./agent.nix inputs;

  # Interactive terminal environment (nix-terminal: zsh/atuin/starship/nvim/tmux)
  # for hosts worked in directly over SSH + zelligate web terminals. Bootstraps
  # Home Manager for the base username and configures programs.nix-terminal.
  terminal = import ./terminal.nix inputs;

  # Retained as an unconsumed graphical skeleton (GNOME). Superseded for the
  # niri laptop by graphical + desktop below; kept for reference.
  gui = import ./gui.nix inputs;

  # Graphical system tier (niri): nixos-core.desktop + input-kanata +
  # cross-compile + nirinit (GAP-C owner). System half of the wayland desktop.
  graphical = import ./graphical.nix inputs;

  # Desktop HM tier: nix-desktop shell (niri/noctalia/walker/workspace-groups)
  # + nix-apps GUI bundles + solaar. Stacks on graphical + terminal.
  desktop = import ./desktop.nix inputs;

  # Declarative secrets (sops-nix): the box decrypts with its own SSH host key.
  secrets = import ./secrets.nix inputs;
}
