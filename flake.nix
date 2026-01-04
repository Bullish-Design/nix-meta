{
  description = "Modular NixOS configurations with centralized settings";

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

  outputs = inputs@{ self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      system = "x86_64-linux";

      # Import profile builders
      profiles = import ./profiles inputs;

      # Helper to build machine configs
      mkMachine = name: profileModules: lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [ (./machines + "/${name}.nix") ] ++ profileModules;
      };
    in
    {
      nixosConfigurations = {
        wsl = mkMachine "wsl" [ profiles.developer ];
        desktop = mkMachine "desktop" [ profiles.developer profiles.gui ];
        server = mkMachine "server" [ profiles.minimal ];
      };
    };
}
