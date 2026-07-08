{ inputs, ... }:

let
  inherit (inputs) home-manager nix-terminal zelligate;

  # The account that owns ~/Documents/Projects and runs the zelligate user daemon.
  user = "andrew";

  # TODO(rollout): set to the tower's real Tailscale MagicDNS name
  # (<tower>.<tailnet>.ts.net) so the index's http://host:port links resolve for
  # remote tailnet devices. A placeholder only makes URLs wrong — the service
  # still runs.
  towerHost = "tower.tailnet.ts.net";
in
{
  imports = [
    # Greenfield tower: hardware-configuration.nix (root fs + bootloader) is
    # added at real install. Without it, `nixos-rebuild build .#server` cannot
    # build the full toplevel — verify the zelligate pieces via the HM
    # activationPackage and the tailscale reconcile script instead.

    home-manager.nixosModules.home-manager
    zelligate.nixosModules.zelligate
  ];

  # ── Login user that owns the workspace and runs the HM daemon ──────────────
  users.users.${user} = {
    isNormalUser = true;
    home = "/home/${user}";
    extraGroups = [ "wheel" ];
    # Linger so the systemd *user* service runs with nobody logged in (headless
    # tower). WITHOUT this the daemon never starts on a headless boot.
    linger = true;
    # Set a password / SSH authorized keys out of band.
  };

  # ── System-level Tailscale Serve wiring (zelligate-owned NixOS module, D1) ──
  # Enables services.tailscale and, in dynamic mode, reconciles Serve rules to
  # the live repo ports (status.json watcher). First `tailscale up`/auth is a
  # one-time manual step on the tower.
  zelligate = {
    enable = true;
    user = user;
    serveMode = "dynamic";
    # indexPort / portRange default to 8122 / 8123-8299.
  };

  # ── Home-Manager: the zelligate user service (systemd --user) ──────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    users.${user} = { ... }: {
      imports = [ nix-terminal.homeManagerModules.zelligate ];

      home.stateVersion = "25.05";
      programs.home-manager.enable = true;

      # The wrapper injects the package + the owned zellij pin; we only set the
      # enable seam and the public host here.
      nix-terminal.zelligate = {
        enable = true;
        publicHost = towerHost;
      };
    };
  };
}
