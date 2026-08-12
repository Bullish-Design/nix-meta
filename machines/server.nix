{ config, inputs, pkgs, ... }:

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
    # DISABLED 2026-07-18: zelligate temporarily removed (not in use). Its
    # per-repo `devenv shell zelligate-manifest` scan was re-realizing every
    # workspace repo's devenv on each cycle — many failing/timing out — churning
    # /nix/store and each repo's .devenv dir. See the zelligate repo's
    # .scratch/projects/08-devenv-scan-store-churn writeup. Re-enable by
    # uncommenting this import plus the home-manager and system `zelligate`
    # blocks below.
    # inputs.zelligate.nixosModules.zelligate
    inputs.nix-paseo.nixosModules.paseo
    # DISABLED 2026-08-01: structured-agents input commented out in flake.nix
    # (repo moved to feature branch project22-llama-cpp-fork-reorg). Uncomment
    # the input + these imports + the two service blocks below together.
    # inputs.structured-agents.nixosModules.structuredAgentsVllm
    # inputs.structured-agents.nixosModules.structuredAgentsLlamaCpp

    # fornix sandbox substrate: the btrfs cortex volume fornix snapshots
    # sandboxes on. All wiring lives in the fornix-host module; we only enable.
    inputs.fornix-host.nixosModules.default

    # Personal SilverBullet notes server, published over Tailscale Serve at
    # https://server.<tailnet>.ts.net/notes. Defaults target this box (andrew /
    # ~/Notes / :443 /notes); we only enable below.
    inputs.silverbullet-server.nixosModules.default

    # Self-hosted Atuin sync server, published over Tailscale Serve at
    # https://server.<tailnet>.ts.net/atuin. Shares HTTPS :443 with
    # SilverBullet — each registers a distinct --set-path route and each
    # ExecStop removes only its own, so the two never clobber each other.
    inputs.pytuin.nixosModules.pytuin-server
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

  # Accept SSH only from the tailnet.  The daemon is enabled by the shared base
  # profile; this host rule makes Framework → server transfers possible without
  # opening port 22 on the LAN or public interfaces.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 8077 ];

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
    # Pi inherits this runtime-only API credential when Paseo launches it.
    # authentication.environmentFile =
    #   config.sops.templates."paseo-deepseek.env".path;
  };

  # DISABLED 2026-08-01 with the structured-agents input: native inference
  # endpoints (vLLM :8000, llama.cpp :8001) are off until the repo's fork reorg
  # lands and is re-locked. Uncomment alongside the input + imports above.
  #
  # # Private native vLLM endpoint: its process binds only to 127.0.0.1:8000.
  # # Tailscale Serve on HTTPS 443 is configured only after local verification.
  # services.structuredAgentsVllm = {
  #   enable = true;
  #   repositoryPath = "/home/andrew/Documents/Projects/structured-agents-v2";
  #   user = user;
  #   group = "users";
  # };
  #
  # # Keep the independent llama.cpp API on loopback :8001, but do not publish
  # # its browser UI through Tailscale HTTPS :8443. Paseo owns that public port.
  # services.structuredAgentsLlamaCpp = {
  #   enable = true;
  #   repositoryPath = "/home/andrew/Documents/Projects/structured-agents-v2";
  #   user = user;
  #   group = "users";
  #   publishViaTailscale = false;
  #   # The 1–5 client MTP sweep needs simultaneous decode slots rather than a
  #   # single queued slot. The fixed 16k total context gives each of five slots
  #   # roughly 3,276 tokens, covering this profile's 1,536-token responses.
  #   parallelSlots = 5;
  # };

  # ── Personal SilverBullet notes server ──────────────────────────────────────
  # Runs on loopback :3000, published by Tailscale Serve at
  # https://server.tail770f47.ts.net/notes. Open auth (no SB_USER/token) — the
  # tailnet ACL is the whole perimeter; scope server:443 to your own devices.
  # Space = ~/Notes (btrfs), git-snapshotted on a timer, group-shared to the
  # dedicated `silverbullet` service user. All defaults target this box, so we
  # only flip enable.
  services.silverbulletServer.enable = true;
  services.silverbulletServer.indexPage = "Notes";

  # ── Self-hosted Atuin sync server ───────────────────────────────────────────
  # Runs on loopback :8888 (PostgreSQL created locally), published by Tailscale
  # Serve at https://server.tail770f47.ts.net/atuin. Same perimeter argument as
  # SilverBullet above: the tailnet ACL is the whole boundary, and the port is
  # exposed on no interface at all — tailscaled proxies to loopback.
  #
  # This is what makes shell history + the Atuin KV store shared across the
  # tailnet (server, framework, …) instead of per-host. It does NOT centralise
  # atuout recordings: atuout has no server component, and command-output
  # captures stay local to the host that ran the command.
  #
  # openRegistration is closed. Atuin has no invite system, so it is the only
  # registration control — an account can only be created while the server is
  # accepting them. To add a machine you already have an account for, you do
  # NOT need this: `atuin login -u <user> -k <key>` works against a closed
  # server. Only a genuinely NEW account needs a bootstrap window:
  #
  #   1. openRegistration = true; nixos-rebuild switch
  #   2. atuin register -u <user> -e <email>   # then `atuin key` — SAVE IT,
  #                                            # it is the only copy
  #   3. set it back to false and rebuild
  #
  # Leave it false in between: while open, anything that reaches the tailnet
  # can create an account.
  services.pytuin.server = {
    enable = true;
    # Same 18.18.1 build the clients run (inputs.atuin), not nixpkgs' 18.16.1
    # default — keeping both ends of the sync protocol on one version removes
    # any record-store skew question. That flake's package ships `atuin-server`
    # alongside `atuin`.
    #
    # The overrideAttrs is byte-identical to profiles/terminal.nix's on purpose:
    # it makes this the SAME derivation the client already builds, so the
    # closure carries one atuin, not two. Dropping it would be harmless
    # semantically (services.atuin only calls `atuin-server` and never reads
    # `.version`) but would fork the derivation hash and trigger a second full
    # Rust compile of the same source. Keep the two expressions in sync.
    package =
      inputs.atuin.packages.${pkgs.stdenv.hostPlatform.system}.atuin.overrideAttrs
        (_: { version = "18.18.0-beta.2"; });
    host = "127.0.0.1"; # Serve proxies to loopback; nothing is bound publicly
    port = 8888;
    openRegistration = false; # see the bootstrap note above before flipping
    database.createLocally = true;
    tailscale = {
      serve = true;
      servePath = "/atuin";
      serveHttpsPort = 443;
    };
  };

  # This switch introduces PostgreSQL to the box for the first time (nothing
  # else here used it), so the first activation initialises a fresh cluster at
  # /var/lib/postgresql/17.
  #
  # Pin the major version explicitly. services.postgresql.package otherwise
  # derives it from system.stateVersion, which means bumping stateVersion later
  # would silently select a newer major — and NixOS does not migrate PostgreSQL
  # data directories, so the service would simply refuse to start against the
  # v17 cluster. Changing this pin is a deliberate dump/restore, never a
  # side effect of an unrelated edit.
  services.postgresql.package = pkgs.postgresql_17;

  # nixpkgs still packages the Go 2.9.0 line (and its expression cannot build
  # the Rust tree). Override with a source build of the 2.10.0 tag
  # (pkgs/silverbullet — npm client + cargo server, version pinned via a
  # build/version.ts patch). The Rust runtime API's headless-Chrome needs
  # (chromium on PATH, SB_CHROME_PATH, writable HOME via RuntimeDirectory,
  # profile outside the space) are provisioned REQUIRED by the
  # silverbullet-server module itself — no host-local wiring (see its
  # runtimeRequired flake check).
  nixpkgs.overlays = [
    (final: prev: {
      silverbullet = final.callPackage ../pkgs/silverbullet { };
    })
  ];

  # ── fornix sandbox substrate ────────────────────────────────────────────────
  # Provision /cortex/fornix as a btrfs loopback owned by andrew and mounted
  # user_subvol_rm_allowed, so fornix's unprivileged `fork`/`clean` (btrfs
  # subvolume snapshot/delete) work and subvolume teardown succeeds.
  # Temporarily disabled (2026-08-01): forgelab is now a plain checkout at
  # ~/Documents/Projects/forgelab, no longer inside the cortex volume. The
  # fornix-host mount unit also has a boot ordering-cycle bug (see FIXME in
  # fornix/nix/fornix-host/module.nix). Re-enable once that's fixed if you want
  # fornix sandboxes back.
  services.fornix-host = {
    enable = false;
    user = user;
  };

  # Delegate the memory cgroup controller (alongside the defaults) to the per-user
  # systemd manager, so fornix's user-scoped sandboxes can set memory limits.
  # Without this `fornix doctor` FAILs with "memory controller not delegated".
  systemd.services."user@".serviceConfig.Delegate = "cpu io memory pids";

  # Keep the physical boot/login console lightweight, but make it comfortable
  # to use when a monitor is attached: a readable Terminus font and a muted dark
  # palette improve legibility without needing a graphical desktop.
  console = {
    keyMap = "us";
    font = "ter-v24n";
    packages = [ pkgs.terminus_font ];
    colors = [
      "1d2021" # black
      "cc241d" # red
      "98971a" # green
      "d79921" # yellow
      "458588" # blue
      "b16286" # magenta
      "689d6a" # cyan
      "a89984" # white
      "928374" # bright black
      "fb4934" # bright red
      "b8bb26" # bright green
      "fabd2f" # bright yellow
      "83a598" # bright blue
      "d3869b" # bright magenta
      "8ec07c" # bright cyan
      "ebdbb2" # bright white
    ];
  };

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

  # ── Declarative SSH for root's flake fetches ────────────────────────────────
  # `sudo nixos-rebuild` evaluates the flake *as root*, so every git+ssh:// input
  # (nix-secrets, zelligate, and loci-core pulled in transitively via
  # nix-terminal) is fetched over root's SSH — which otherwise has no known_hosts
  # and no key of its own, giving an interactive host-key prompt followed by
  # `Permission denied (publickey)`. Two declarative pieces replace hand-editing
  # /root/.ssh: both land in /etc/ssh (fleet-wide, root included).
  programs.ssh = {
    # 1. Pin GitHub's host key so the eval never stops at an interactive
    #    "authenticity of host 'github.com' can't be established" prompt.
    knownHosts.github = {
      hostNames = [ "github.com" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };

    # 2. Authenticate to GitHub with ${user}'s existing key (root can read it) so
    #    the private git+ssh inputs resolve during the rebuild. Written to the
    #    global /etc/ssh/ssh_config, so it also covers ${user}'s own git-over-SSH
    #    (same key, already in use). Swap to a dedicated /root/.ssh deploy key
    #    later if root should have independent, separately-revocable access.
    extraConfig = ''
      Host github.com
        User git
        IdentityFile /home/${user}/.ssh/id_ed25519
        IdentitiesOnly yes
    '';
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

  # DISABLED 2026-07-18: zelligate user service commented out (not in use).
  # profiles.developer already bootstraps home-manager for ${user}, so this
  # host-local block existed only to run the zelligate daemon. Re-enable
  # alongside the import and system `zelligate` block to restore the workspace
  # daemon. (See .scratch/projects/08-devenv-scan-store-churn in the zelligate
  # repo for why it was pulled.)
  # home-manager = {
  #   useGlobalPkgs = true;
  #   useUserPackages = true;
  #
  #   users.${user} = { ... }: {
  #     imports = [ inputs.zelligate.homeManagerModules.zelligate ];
  #
  #     home.stateVersion = "25.05";
  #
  #     services.zelligate = {
  #       enable = true;
  #       package = inputs.zelligate.packages.${pkgs.system}.default;
  #       # No owned zellij pin in the fleet yet; nixpkgs-unstable ships 0.44.3,
  #       # whose `web` subcommand has the token interface zelligate drives.
  #       zellijPackage = pkgs.zellij;
  #       # The tower's Tailscale MagicDNS FQDN — the index builds each repo's
  #       # http://<publicHost>:<port> launcher link from this, so it must be a name
  #       # remote tailnet devices resolve. Verified reachable: a tailnet peer gets
  #       # HTTP 200 on http://server.tail770f47.ts.net:8122.
  #       publicHost = "server.tail770f47.ts.net";
  #     };
  #   };
  # };

  # System-level Tailscale-Serve wiring (needs root; tailscaled itself is already
  # enabled by nixos-core.base, so we don't re-enable it here). Dynamic mode: a
  # status.json watcher reconciles Serve rules to the live repo ports.
  # DISABLED 2026-07-18: see the import + home-manager blocks above.
  # zelligate = {
  #   enable = true;
  #   user = user;
  #   serveMode = "dynamic";
  #   tailscale.enable = false; # base tier already owns services.tailscale
  # };

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
