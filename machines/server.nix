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
  # access on the box is unaffected. Add your public key for remote login — paste
  # it here, or fill from the box in Phase B: `cat ~/.ssh/id_ed25519.pub`.
  users.users.${user}.openssh.authorizedKeys.keys = [
    # "ssh-ed25519 AAAA... andrew@framework"
  ];
}
