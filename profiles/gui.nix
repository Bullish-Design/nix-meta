inputs:
{ pkgs, ... }:

{
  # GUI-specific packages and settings
  nixos-core.common.systemPackages = with pkgs; [
    firefox
    kitty
  ];

  # GUI environment configuration
  services.xserver.enable = true;
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;
}
