inputs:
{ pkgs, ... }:

{
  # Dormant graphical profile. System packages are configured directly.
  environment.systemPackages = with pkgs; [
    firefox
    kitty
  ];

  # GUI environment configuration
  services.xserver.enable = true;
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;
}
