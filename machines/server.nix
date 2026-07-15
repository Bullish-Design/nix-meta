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
    inputs.nix-paseo.nixosModules.paseo
    inputs.structured-agents.nixosModules.structuredAgentsVllm
    inputs.structured-agents.nixosModules.structuredAgentsLlamaCpp
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

  # Developer workflow policy is host-owned: the shared profile provides the
  # tools and user-relative defaults, while this box chooses its organization
  # checkout set. The root matches paseo/zelligate's opt-in workspace scan.
  nix-meta.developer = {
    nixbuild.outputDir = "/home/${user}/.nixbuild-logs";
    repoman = {
      baseDir = "/home/${user}/Documents/Projects";
      accounts = [
        {
          name = "Bullish-Design";
          repos = [
            "nix-meta"
            "nixos-core"
            "nix-terminal"
            "nixvim"
            "terminal-state"
            "devman"
            "gitman"
          ];
        }
      ];
    };
  };

  nix-paseo.paseo = {
    enable = true;

    user = "andrew";
    group = "users";
    workspaceRoot = "/home/andrew/Documents/Projects";

    tailnet = {
      # Tailscale Serve terminates TLS at :8443 and proxies to Paseo's loopback
      # listener. Browser microphone APIs require this HTTPS secure context.
      # HTTPS Serve is configured below; keep Paseo loopback-only otherwise.
      enable = false;
      hostname = "server.tail770f47.ts.net";
      https = {
        enable = true;
        port = 8443;
      };
    };

    # Temporary bootstrap posture. Do not add sops password plumbing yet.
    authentication.requirePassword = false;
  };

  # Private native vLLM endpoint: its process binds only to 127.0.0.1:8000.
  # Tailscale Serve on HTTPS 443 is configured only after local verification.
  services.structuredAgentsVllm = {
    enable = true;
    repositoryPath = "/home/andrew/Documents/Projects/structured-agents-v2";
    user = user;
    group = "users";
  };

  # Keep the independent llama.cpp API on loopback :8001, but do not publish
  # its browser UI through Tailscale HTTPS :8443. Paseo owns that public port.
  services.structuredAgentsLlamaCpp = {
    enable = true;
    repositoryPath = "/home/andrew/Documents/Projects/structured-agents-v2";
    user = user;
    group = "users";
    publishViaTailscale = false;
    # The 1–5 client MTP sweep needs simultaneous decode slots rather than a
    # single queued slot. The fixed 16k total context gives each of five slots
    # roughly 3,276 tokens, covering this profile's 1,536-token responses.
    parallelSlots = 5;
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
    # Serial access to the Waveshare ESP32-S3 wired on /dev/ttyACM0 (root:dialout).
    # `adbusers`: USB access to the plugged-in Android phone for adb (09/servomat
    # HIL host; programs.adb.enable below installs the group + udev rules).
    # Host-scoped: only `server` has this hardware attached. Merges (list-concat)
    # with base.nix's [ "networkmanager" "wheel" "docker" ]. (008/interplay +
    # 009/servomat HIL host.)
    extraGroups = [ "dialout" "adbusers" ];
  };

  # Android debugging over USB for the plugged-in phone (009/servomat round-trip
  # host) — the exact analog of `dialout` for the ESP32 board above.
  #
  # `programs.adb` and `pkgs.android-udev-rules` were BOTH removed upstream
  # (nixpkgs 26.11), superseded by systemd's built-in `uaccess`. But `uaccess`
  # grants the *active local seat* user only; this box is driven headless over
  # SSH / the paseo agent (all sessions have SEAT=-), so uaccess grants nothing.
  # We therefore author a group-based rule ourselves: the phone's USB node
  # becomes adbusers:0660 and any adbusers member (andrew, above) opens it
  # without root. Host-scoped: only `server` has a phone attached.
  #
  # adb itself is NOT installed system-wide — like mpremote/esptool for 008, the
  # tool is pinned in servomat's devenv.nix; this rule only grants the access.
  users.groups.adbusers = { };
  services.udev.extraRules = ''
    # Android ADB: USB device nodes for known handset vendors → adbusers:0660.
    # 04e8 = Samsung (the attached Galaxy, serial R5CN704TT9P); 18d1 = Google.
    SUBSYSTEM=="usb", ATTR{idVendor}=="04e8", MODE="0660", GROUP="adbusers"
    SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0660", GROUP="adbusers"
  '';

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
