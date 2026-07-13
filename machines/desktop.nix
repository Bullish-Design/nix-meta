{ config, inputs, pkgs, ... }:

let
  username = config.nixos-core.base.username;
in

{
  imports = [
    # Add desktop-specific hardware configuration
  ];

  # Desktop-specific package additions
  home-manager.users.${username} = {
    programs.nix-terminal.extraPackages = with pkgs; [
      docker-compose
    ];
  };
}
