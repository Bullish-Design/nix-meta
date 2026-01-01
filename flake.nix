{
  description = "Modular NixOS bootstrap (remote GitHub rebuild, git+https inputs)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-core.url = "git+https://github.com/Bullish-Design/nixos-core.git?ref=main";

    home-manager = {
      url = "git+https://github.com/nix-community/home-manager.git?ref=master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-terminal = {
      url = "git+https://github.com/Bullish-Design/nix-terminal.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, nixos-core, home-manager, nix-terminal, ... }:
  let
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

          home-manager.users.nixos = { ... }: {
            imports = [ 
              nix-terminal.homeManagerModules.terminal 
            ];
            
            home.stateVersion = "25.05";
            
            # Home Manager flags:
            programs.home-manager.enable = true;
            programs.nix-terminal.enable = true;
          };
        })
      ];
    };
  };
}
