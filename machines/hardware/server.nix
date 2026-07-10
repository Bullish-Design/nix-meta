# Generated on the box by `nixos-generate-config` (Dell Precision 5820).
# Do not modify — regenerate on the box and copy back if the hardware changes.
# Bootloader + host-specific boot options live in machines/server.nix instead.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "vmd" "usbhid" "usb_storage" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/e6b180fa-534a-4b71-aff8-f9fe2e6d0834";
      fsType = "btrfs";
      options = [ "subvol=@" ];
    };

  fileSystems."/home" =
    { device = "/dev/disk/by-uuid/e6b180fa-534a-4b71-aff8-f9fe2e6d0834";
      fsType = "btrfs";
      options = [ "subvol=@home" ];
    };

  fileSystems."/nix" =
    { device = "/dev/disk/by-uuid/e6b180fa-534a-4b71-aff8-f9fe2e6d0834";
      fsType = "btrfs";
      options = [ "subvol=@nix" ];
    };

  fileSystems."/var" =
    { device = "/dev/disk/by-uuid/e6b180fa-534a-4b71-aff8-f9fe2e6d0834";
      fsType = "btrfs";
      options = [ "subvol=@var" ];
    };

  fileSystems."/.snapshots" =
    { device = "/dev/disk/by-uuid/e6b180fa-534a-4b71-aff8-f9fe2e6d0834";
      fsType = "btrfs";
      options = [ "subvol=@snapshots" ];
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/0086-EC69";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/5445f100-dc12-4d50-b7b2-24f7d4d3b9a9"; }
    ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
