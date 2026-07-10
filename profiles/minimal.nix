inputs:
{ pkgs, ... }:

let
  inherit (inputs) nixos-core;
in
{
  imports = [
    nixos-core.nixosModules.base
  ];

  # system.stateVersion is per-host (tracks each box's install) — set in the
  # machine module, not this shared profile.

  nixos-core.base = {
    enable = true;
    enableFlakes = true;
    experimentalFeatures = [ "nix-command" "flakes" ];
    systemPackages = with pkgs; [
      git
    ];
  };
}
