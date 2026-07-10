inputs:
{ pkgs, ... }:

let
  inherit (inputs) nixos-core;
in
{
  imports = [
    nixos-core.nixosModules.base
  ];

  system.stateVersion = "25.05";

  nixos-core.base = {
    enable = true;
    enableFlakes = true;
    experimentalFeatures = [ "nix-command" "flakes" ];
    systemPackages = with pkgs; [
      git
    ];
  };
}
