{ inputs, pkgs, ... }:

{
  imports = [
    # Add desktop-specific hardware configuration
  ];

  # Desktop-specific package additions
  home-manager.users.nixos = {
    programs.nix-terminal.extraPackages = with pkgs; [
      docker-compose
    ];
  };
}
