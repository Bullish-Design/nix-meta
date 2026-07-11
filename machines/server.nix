{ inputs, pkgs, ... }:

let
  # The account that owns ~/Documents/Projects on the box.
  user = "andrew";
in
{
  imports = [
    ./hardware/server.nix

    # Phase C — the zelligate workspace daemon. Both modules are authored in the
    # zelligate repo (all config lives there); the server only imports + enables.
    inputs.home-manager.nixosModules.home-manager
    inputs.zelligate.nixosModules.zelligate
  ];

  # ── Bootloader: systemd-boot on the EFI partition at /boot (UEFI) ───────────
  # (These live here, not in the generated hardware file, per NixOS convention.)
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot";
  boot.loader.timeout = 5;

  # Dell/Intel platform exposes the NVMe root via Intel VMD (BIOS "RAID On" mode
  # for Windows compat) — keep vmd in the initrd so root is visible at boot.
  boot.initrd.kernelModules = [ "vmd" ];
  boot.supportedFilesystems = [ "btrfs" "ntfs" "vfat" ];
  hardware.enableRedistributableFirmware = true;

  # ── Host identity ───────────────────────────────────────────────────────────
  # base tier (profiles.minimal) owns nix flakes, the user account, zsh,
  # networking, ssh (key-only), tailscale, docker, locale/time. Set only the
  # per-host bits here.
  nixos-core.base = {
    hostName = "server";
    username = user;
    # tailscale.enable defaults true; run `tailscale up` once on the box.
  };

  console.keyMap = "us";

  # Install terminfo for all terminals so SSH sessions from any client (e.g. the
  # framework's kitty → TERM=xterm-kitty) resolve cleanly. Host-agnostic — could
  # move to nixos-core.base later.
  environment.enableAllTerminfo = true;

  # ── Server housekeeping (carried from the box's prior config) ───────────────
  zramSwap.enable = true; # 32 GB RAM box
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;

  # stateVersion tracks the box's original install — do NOT bump casually.
  system.stateVersion = "26.05";

  # Remote SSH is key-only (base sets PasswordAuthentication = false). Console
  # access on the box is unaffected. These are the framework laptop's keys.
  # `linger` (Phase C) keeps the zelligate systemd USER service running with
  # nobody logged in — WITHOUT it the daemon never starts on a headless boot.
  # Both settings share one attrset: a dynamic key (`${user}`) can't be split
  # across two separate `users.users.${user}.…` statements.
  users.users.${user} = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEtXr8bHPY+hfPDaQaYAhfnaayVSuWH3+KYC6CR8ETnc andrew@framework"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICesVdfKGESibctJ+Au8HQ+6exX3BpLdPm192bBsCec9 andrew@framework-nixos"
    ];
    linger = true;
  };

  # ── Phase C: zelligate workspace daemon ─────────────────────────────────────
  # The daemon (`zelligated`) runs as a systemd USER service under `${user}`,
  # scanning ~/Documents/Projects for opted-in repos and serving each as a Zellij
  # web terminal on loopback. A system-level Tailscale-Serve module (below) bridges
  # the tailnet to those loopback ports. All wiring is imported from the zelligate
  # flake; nothing here is authored — we only enable and inject the box-specific
  # bits (the user, the package, the zellij binary, the public host).

  # Home-Manager is greenfield on this host (minimal carries none). Enable it for
  # the login user just enough to run the zelligate user service.
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    users.${user} = { ... }: {
      imports = [ inputs.zelligate.homeManagerModules.zelligate ];

      home.stateVersion = "25.05";

      services.zelligate = {
        enable = true;
        package = inputs.zelligate.packages.${pkgs.system}.default;
        # No owned zellij pin in the fleet yet; nixpkgs-unstable ships 0.44.3,
        # whose `web` subcommand has the token interface zelligate drives.
        zellijPackage = pkgs.zellij;
        # The tower's Tailscale MagicDNS FQDN — the index builds each repo's
        # http://<publicHost>:<port> launcher link from this, so it must be a name
        # remote tailnet devices resolve. Verified reachable: a tailnet peer gets
        # HTTP 200 on http://server.tail770f47.ts.net:8122.
        publicHost = "server.tail770f47.ts.net";
      };
    };
  };

  # System-level Tailscale-Serve wiring (needs root; tailscaled itself is already
  # enabled by nixos-core.base, so we don't re-enable it here). Dynamic mode: a
  # status.json watcher reconciles Serve rules to the live repo ports.
  zelligate = {
    enable = true;
    user = user;
    serveMode = "dynamic";
    tailscale.enable = false; # base tier already owns services.tailscale
  };

  # Optional shared NTFS data drive. nofail = won't block boot if absent/dirty.
  fileSystems."/mnt/shared" = {
    device = "/dev/disk/by-label/SHARED";
    fsType = "ntfs3";
    options = [
      "nofail"
      "x-systemd.automount"
      "uid=1000"
      "gid=100"
      "umask=022"
      "windows_names"
    ];
  };
}
