{ inputs, ... }:

let
  # The account that owns ~/Documents/Projects on the box.
  user = "andrew";
in
{
  imports = [
    # Hardware config (bootloader + root/boot filesystems). Phase B: overwrite
    # machines/hardware/server.nix with the running box's real
    # /etc/nixos/hardware-configuration.nix, then `nixos-rebuild switch`.
    ./hardware/server.nix
  ];

  # ── Base tier (nixos-core.base) owns: nix flakes, the user account, zsh,
  # networking, ssh (key-only), tailscale, docker, locale/time. profiles.minimal
  # enables it; here we only set the per-host identity. ────────────────────────
  nixos-core.base = {
    hostName = "server";
    username = user;
    # tailscale.enable defaults true; run `tailscale up` once on the box.
  };

  # Remote SSH is key-only (base sets PasswordAuthentication = false). Console
  # access on the box is unaffected. These are the framework laptop's keys:
  # id_ed25519 (default identity → plain `ssh server` works) + the dedicated
  # NixOS key.
  users.users.${user}.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEtXr8bHPY+hfPDaQaYAhfnaayVSuWH3+KYC6CR8ETnc andrew@framework"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICesVdfKGESibctJ+Au8HQ+6exX3BpLdPm192bBsCec9 andrew@framework-nixos"
  ];
}
