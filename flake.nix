{
  description = "Modular NixOS configurations with centralized settings";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-core.url = "git+https://github.com/Bullish-Design/nixos-core.git?ref=main";

    nix-paseo = {
      url = "git+file:///home/andrew/Documents/Projects/nix-paseo?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "git+https://github.com/nix-community/home-manager.git?ref=master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative secrets. nix-secrets is the sops-nix WRAPPER (provider): it
    # owns the sops-nix pin and re-exports the NixOS module, so nix-meta consumes
    # `nixosModules.secrets` and gets sops-nix transitively — we never re-pin it
    # here. The box decrypts with its own SSH host key (age identity); the
    # encrypted store + recipients live inside the nix-secrets flake.
    nix-secrets = {
      url = "git+ssh://git@github.com/Bullish-Design/nix-secrets.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Phase C: the workspace daemon (zelligate) is layered onto the server.
    # zelligate is a private repo, pulled over the SSH input form (same
    # convention as nix-secrets above), NOT a laptop `path:`. It exposes the two
    # modules the server imports directly (nix-meta authors nothing): a
    # Home-Manager user-service module and a system-level Tailscale-Serve module.
    zelligate = {
      url = "git+ssh://git@github.com/Bullish-Design/zelligate.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The interactive terminal environment (zsh/atuin/starship/nvim/tmux) — the
    # rich shell you get over SSH and inside zelligate web terminals. The tower
    # is a host worked IN directly, which is exactly this flake's purpose, so it
    # belongs in the server set. Fetched as a git input (public repo, like
    # nixos-core) — NOT the old laptop `path:` that broke the on-box build.
    nix-terminal = {
      url = "git+https://github.com/Bullish-Design/nix-terminal.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Shellij is developed on this server and supplies the Home Manager module
    # for durable project workbenches. Use Git source filtering so generated
    # devenv state is never copied into the Nix store as part of this input.
    shellij = {
      url = "git+file:///home/andrew/Documents/Projects/shellij";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    # Native inference service modules. Use the local Git source form so Nix
    # snapshots only Git-tracked source files; a raw path input would recursively
    # copy generated deployment environments (currently tens of gigabytes) into
    # the store on every content change.
    structured-agents = {
      url = "git+file:///home/andrew/Documents/Projects/structured-agents-v2";
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
        # Minimal headless server (Dell Precision 5820). The wsl/desktop skeleton
        # hosts were retired for this bring-up; grow the fleet back out from the
        # box via `nixos-rebuild switch --flake .#server`.
        # profiles.terminal restored: nix-terminal now consumes nix-nvim (the
        # loci-rich config promoted from ~/.dotfiles/nvim) instead of the retired,
        # broken nixvim input.
        server = mkMachine "server" [ profiles.minimal profiles.terminal profiles.developer profiles.gpu-compute profiles.agent profiles.secrets ];
      };
    };
}
