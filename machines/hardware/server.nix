# ┌──────────────────────────────────────────────────────────────────────────┐
# │  PLACEHOLDER — NOT A REAL HARDWARE CONFIG. DO NOT DEPLOY AS-IS.             │
# │                                                                            │
# │  Exists only so `nix eval`/`nix flake check` can evaluate the `server`     │
# │  toplevel off-box (the root-fs + bootloader assertions need *something*).  │
# │                                                                            │
# │  Phase B, on the running Dell: overwrite this file with the box's real     │
# │  generated hardware config, then rebuild:                                  │
# │                                                                            │
# │    cp /etc/nixos/hardware-configuration.nix \                              │
# │       <flake>/machines/hardware/server.nix                                 │
# │    sudo nixos-rebuild switch --flake <flake>#server                        │
# │                                                                            │
# │  The real file carries the correct disk UUIDs, filesystems, boot loader,   │
# │  and kernel modules for this box — this stub carries none of them.         │
# └──────────────────────────────────────────────────────────────────────────┘
{ lib, ... }:
{
  # Minimal placeholder root fs + bootloader so evaluation succeeds. These
  # values are deliberately generic and will be replaced wholesale in Phase B.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = lib.mkDefault "nodev";

  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
}
