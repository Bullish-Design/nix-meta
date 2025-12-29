{
  description = "WSL bootstrap (remote GitHub rebuild)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
  };

  outputs = { self, nixpkgs, nixos-wsl, ... }:
  let
    system = "x86_64-linux";
  in {
    nixosConfigurations.wsl = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        nixos-wsl.nixosModules.default
        ({ pkgs, ... }: {
          wsl.enable = true;

          # Don’t rely on local /etc/nixos for enabling flakes.
          nix.settings.experimental-features = [ "nix-command" "flakes" ];

          environment.systemPackages = with pkgs; [ 
            git 
            nvim 
          ];
          system.stateVersion = "25.05";
        })
      ];
    };
  };
}
