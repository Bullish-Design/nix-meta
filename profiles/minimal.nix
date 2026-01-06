inputs:
{ pkgs, ... }:

let
  inherit (inputs) nixos-core;
in
{
  imports = [
    nixos-core.nixosModules.common
  ];

  system.stateVersion = "25.05";

  nixos-core.common = {
    enableFlakes = true;
    experimentalFeatures = [ "nix-command" "flakes" ];
    systemPackages = with pkgs; [
      git
      #vim
    ];
  };
}
