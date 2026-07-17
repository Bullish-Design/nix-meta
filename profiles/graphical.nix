inputs:
{ pkgs, lib, ... }:

let
  inherit (inputs) nixos-core nirinit;
in
{
  # ── Graphical system tier ────────────────────────────────────────────────
  # The "graphical" rung of the UI ladder: base → terminal → *graphical* →
  # desktop. Owns the SYSTEM half of the wayland desktop (DM/session/seat/audio/
  # fonts/wl-utils + programs.niri.enable + bluetooth/power/printing + the
  # niri/noctalia cachix). The HM half (niri config.kdl, noctalia, walker,
  # workspace-groups) lives in profiles/desktop.nix via the nix-desktop repo.
  #
  # Also folds in the two orthogonal capabilities the framework laptop carries
  # at this tier: kanata (input remapping) and cross-compile (aarch64 binfmt).
  imports = [
    nixos-core.nixosModules.desktop
    nixos-core.nixosModules.input-kanata
    nixos-core.nixosModules.cross-compile

    # GAP-C owner: nixos-core.desktop deliberately does NOT take the nirinit
    # input (keeps the headless tower clean), so the graphical-tier consumer
    # carries it. Without this, base.kdl's `spawn-at-startup "nirinit restore"`
    # is a silent no-op. Provides services.nirinit (session restore).
    nirinit.nixosModules.nirinit
  ];

  nixos-core.desktop = {
    enable = true;
    # programs.niri.enable + GDM defaultSession = niri. The programs.niri module
    # itself is provided by nixpkgs (the dotfiles set it with no niri flake
    # input), so nixos-core.desktop can turn it on directly.
    niri.enable = true;
    # The dotfiles kept GNOME enabled as a fallback session alongside niri.
    gnome.enable = true;
    # audio / bluetooth / power / printing / cachix all default true — matches
    # the dotfiles (PipeWire, bluetooth, upower+power-profiles, CUPS, niri+
    # noctalia cachix). Left implicit so the module defaults own them.
  };

  # aarch64 emulation (dotfiles: boot.binfmt.emulatedSystems = ["aarch64-linux"]).
  nixos-core.cross-compile.enable = true;

  # kanata system service — fragments in nixos-core are byte-identical to the
  # dotfiles set.
  nixos-core.input-kanata.enable = true;

  # Session restore daemon (GAP-C). Mirrors the dotfiles niri-session.nix.
  services.nirinit = {
    enable = true;
    settings = {
      skip.apps = [ ];
      launch = { };
    };
  };
}
