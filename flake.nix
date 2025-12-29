{
  description = "Modular NixOS bootstrap (remote GitHub rebuild)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-core.url = "github:Bullish-Design/nixos-core";
  };

  outputs = inputs@{ self, nixpkgs, nixos-core, ... }:
  let
    system = "x86_64-linux";
  in {
    nixosConfigurations.wsl = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        nixos-core.nixosModules.wsl-upstream
        nixos-core.nixosModules.wsl
        nixos-core.nixosModules.common
        ({ ... }: { system.stateVersion = "25.05"; })
      ];
    };
  };
}
