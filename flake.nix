{
  description = "Modular NixOS configurations with centralized settings";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-core.url = "git+https://github.com/Bullish-Design/nixos-core.git?ref=main";

    home-manager = {
      url = "git+https://github.com/nix-community/home-manager.git?ref=master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NOTE: the nix-terminal / zelligate `path:` inputs were removed for the
    # minimal `server` bring-up — those absolute laptop paths don't exist on the
    # box and would break the on-box build. They come back (as git inputs) in
    # Phase C when the workspace daemon is layered on from the server itself.
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
        # Minimal headless server (Dell Precision 5820). The wsl/desktop skeleton
        # hosts were retired for this bring-up; grow the fleet back out from the
        # box via `nixos-rebuild switch --flake .#server`.
        server = mkMachine "server" [ profiles.minimal profiles.gpu-compute ];
      };
    };
}
