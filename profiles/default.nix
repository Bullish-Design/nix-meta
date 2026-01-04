inputs:
let
  inherit (inputs) nixpkgs home-manager nixos-core nix-terminal;
in
{
  developer = import ./developer.nix inputs;
  minimal = import ./minimal.nix inputs;
  gui = import ./gui.nix inputs;
}
