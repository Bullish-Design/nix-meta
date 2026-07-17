inputs:
{ config, pkgs, lib, ... }:

let
  inherit (inputs) nix-desktop nix-apps home-manager;

  # Username SSOT — same pattern as terminal.nix.
  username = config.nixos-core.base.username;
in
{
  # ── LLM-CLI ownership ─────────────────────────────────────────────────────
  # nix-apps' llmCli bundle is the single owner of the LLM CLIs
  # (opencode/codex/qwen/antigravity/claude-code). devman-tools used to *also*
  # bundle claude+codex, which collided with these in the merged home.packages
  # buildEnv. Fixed at the source: devman-tools no longer bundles the LLM CLIs
  # (devman `no-llm-tools`), consumed via nix-terminal's `devman` follows in
  # flake.nix. No priority juggling needed here.

  # ── Desktop tier (HM half) ────────────────────────────────────────────────
  # Top rung of the UI ladder. Adds the wayland shell (nix-desktop:
  # niri/noctalia/walker/workspace-groups) and the GUI application bundles
  # (nix-apps) on top of the graphical system tier. Pairs with
  # profiles/graphical.nix (the system half).
  #
  # HM is wired defensively (mkDefault) so a host that also imports the terminal
  # profile — which sets the same toggles — merges cleanly.
  imports = [ home-manager.nixosModules.home-manager ];

  home-manager = {
    useGlobalPkgs = lib.mkDefault true;
    useUserPackages = lib.mkDefault true;
    backupFileExtension = lib.mkDefault "hm-backup";

    users.${username} = { ... }: {
      imports = [
        # nix-desktop's aggregate imports all four components; each stays behind
        # its own programs.nix-desktop.<c>.enable, so importing the aggregate is
        # inert until the enables below flip.
        nix-desktop.homeManagerModules.desktop
        nix-apps.homeManagerModules.apps
      ];

      home.stateVersion = lib.mkDefault "25.05";

      # ── Wayland shell (nix-desktop) ──────────────────────────────────────
      programs.nix-desktop = {
        niri.enable = true;
        noctalia.enable = true;
        walker.enable = true;
        workspace-groups.enable = true;
      };

      # ── GUI application bundles (nix-apps) ────────────────────────────────
      # Full desktop coverage — mirrors the dotfiles home.packages GUI surface.
      # Note: nix-apps is GUI-only; the ambient CLI/dev tooling from the
      # dotfiles home.packages is handled separately (nix-terminal.extraPackages
      # in machines/framework.nix, and devenv-lib for toolchains).
      nix-apps.apps = {
        enable = true;
        browsers.enable = true;
        creative.enable = true;
        office.enable = true;
        media.enable = true;
        llmCli.enable = true;
        notes.enable = true;
        editors.enable = true;
      };

      # ── solaar (Logitech device manager) ─────────────────────────────────
      # No component owns this yet (recommendation: promote to a nix-desktop
      # component later). Carried inline for parity: package + user service.
      # config.yaml is NOT declaratively managed here (the dotfiles wrote it via
      # activation) — revisit when promoting to nix-desktop.
      home.packages = [ pkgs.solaar ];
      systemd.user.services.solaar = {
        Unit = {
          Description = "Solaar - Logitech device manager";
          PartOf = [ "graphical-session.target" ];
        };
        Service = {
          ExecStart = "${pkgs.solaar}/bin/solaar --window=hide";
          Restart = "on-failure";
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
