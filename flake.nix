{
  description = "Modular NixOS configurations with centralized settings";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-core.url = "git+https://github.com/Bullish-Design/nixos-core.git?ref=main";

    home-manager = {
      url = "git+https://github.com/nix-community/home-manager.git?ref=master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Dev: local path so the tower gets nix-terminal's zelligate HM wrapper +
    # bumped zellij pin before they are published. repoman fleet flake-update
    # rewrites these to git+…?ref=<tag> at publish.
    nix-terminal = {
      url = "path:/home/andrew/Documents/Projects/nix-terminal";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # zelligate's own flake — for nixosModules.zelligate (system Tailscale Serve).
    # The HM side arrives via nix-terminal's wrapper; this input is the system half.
    zelligate = {
      url = "path:/home/andrew/Documents/Projects/zelligate";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
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
