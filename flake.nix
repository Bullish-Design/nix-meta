{
  description = "Modular NixOS bootstrap (remote GitHub rebuild)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-core.url = "github:Bullish-Design/nixos-core/main";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-terminal = {
      url = "github:Bullish-Design/nix-terminal/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, nixos-core, home-manager, nix-terminal, ... }:  let
    system = "x86_64-linux";
  in {
    nixosConfigurations.wsl = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        nixos-core.nixosModules.wsl-upstream
        nixos-core.nixosModules.wsl
        nixos-core.nixosModules.common


        home-manager.nixosModules.home-manager
        ({ ... }: {
          system.stateVersion = "25.05";

          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;

          # Remote-only approach: set your username explicitly:
          home-manager.users.nixos = { ... }: {
            imports = [ nix-terminal.homeManagerModules.terminal ];
            home.stateVersion = "25.05";
            programs.home-manager.enable = true;
          };
        })
      ];
    };
  };
}
