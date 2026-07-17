{ config, inputs, pkgs, lib, ... }:

let
  user = "andrew";
in
{
  imports = [
    ./hardware/framework.nix

    # Personal daemon: provisions the /cortex/fornix btrfs volume for sandbox
    # forks (host-identity capability; the tower does not carry it).
    inputs.fornix-host.nixosModules.default
  ];

  # ── Bootloader: systemd-boot on the EFI partition at /boot (UEFI) ───────────
  # (Lives in the machine module, not the generated hardware file, per NixOS
  # convention — mirrors machines/server.nix.)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ── Host identity ───────────────────────────────────────────────────────────
  # base tier (profiles.minimal) owns nix flakes, the user account, zsh,
  # networking, ssh (key-only), tailscale, docker, locale/time, nix-ld,
  # appimage. Set only the per-host bits here.
  nixos-core.base = {
    hostName = "framework";
    username = user;
    # tailscale.enable defaults true.
  };

  # Accept SSH only from the tailnet (dotfiles parity).
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];

  # Framework firmware updates (dotfiles: services.fwupd.enable).
  services.fwupd.enable = true;

  # fornix sandbox-fork host (dotfiles: services.fornix-host).
  services.fornix-host = {
    enable = true;
    user = user;
  };

  # Insecure packages the dotfiles permitted (Element/matrix deps).
  nixpkgs.config.permittedInsecurePackages = [
    "olm-3.2.16"
    "libsoup-2.74.3"
  ];

  # ── Syncthing (host data) ───────────────────────────────────────────────────
  # Device IDs and the shared "notes" folder, carried verbatim from the dotfiles.
  services.syncthing = {
    enable = true;
    guiAddress = "127.0.0.1:8384";
    openDefaultPorts = true;
    user = user;
    group = "users";
    dataDir = "/home/${user}";
    configDir = "/home/${user}/.config/syncthing";
    settings = {
      devices = {
        pi = {
          id = "D2C6YFJ-2BC4Z7W-4QWJBSR-HBBGSRX-7JRXDZS-AI2W732-3LFQRBL-MJ55VQX";
          introducer = true;
        };
        laptop = {
          id = "RBTYZI7-GWMLVEN-75ZPH7S-EV5CWYY-OGYCPPE-EPJBCJC-C7EDBZE-HZFYNA2";
        };
      };
      folders."notes" = {
        path = "/home/${user}/Documents/Notes";
        devices = [ "pi" "laptop" ];
        ignorePerms = true;
      };
    };
  };

  # ── Home-Manager: framework-user host bits ──────────────────────────────────
  # HM itself is wired by the terminal/desktop profiles; this adds the per-host
  # user config (shellij client, ambient CLI packages, cursor, session vars).
  # A single users.${user} module — separate dynamic-attribute paths would
  # collide.
  home-manager.users.${user} = { ... }: {
    imports = [ inputs.shellij.homeManagerModules.default ];

    # Shellij attach-only client + ssh to the workbench host (dotfiles home.nix).
    programs.shellij = {
      enable = true;
      projectsRoot = null;
    };
    programs.ssh.matchBlocks.shellij-server = {
      hostname = "server.tail770f47.ts.net";
      user = user;
    };

    # ── Ambient CLI utilities (recommendation §2) ─────────────────────────────
    # The dotfiles home.packages CLI/util slice that is neither GUI (nix-apps)
    # nor in nix-terminal's small corePackages. These belong at the terminal
    # plane — you expect them at every prompt. Language TOOLCHAINS
    # (gcc/go/cargo/nim/node/uv/python env/playwright) are intentionally NOT
    # here — they move to devenv-lib per the migration plan.
    programs.nix-terminal.extraPackages = with pkgs; [
      # search / files / view
      fd ripgrep ast-grep yq jq tree tldr file w3m yazi
      # system / disk / sensors
      htop lm_sensors parted gparted openssl bc unzip wget curl xdg-utils
      # data
      sqlite postgresql visidata
      # wayland / desktop helpers (CLI)
      wl-clipboard grim slurp wofi brightnessctl xdotool wmctrl
      # vcs / diff
      tig delta diffsitter git-filter-repo
      # nix
      statix graphviz
      # media / audio libs used by scripts
      portaudio
      # emulation helper (pairs with cross-compile)
      qemu-user
      # bluetooth applet
      blueman
    ];

    # Bibata cursor + session vars (dotfiles home.nix).
    home.pointerCursor = {
      enable = true;
      gtk.enable = true;
      x11.enable = true;
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
      size = 24;
    };
    home.sessionVariables = {
      EDITOR = "nvim";
      TERMINAL = "kitty";
      LC_TIME = "en_US.UTF-8";
      XCURSOR_SIZE = "24";
    };
  };

  # stateVersion tracks the laptop's original install — matches the dotfiles.
  system.stateVersion = "23.11";
}
