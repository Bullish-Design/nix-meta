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
    # The codex/claude collision is now fixed at the SOURCE: nix-meta overrides
    # nix-terminal's transitive `devman` input with a devman that no longer
    # bundles the LLM CLIs (see the `devman` input + follows below). So this
    # points at plain github main again — no lowPrio branch needed.
    nix-terminal = {
      url = "git+https://github.com/Bullish-Design/nix-terminal.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
      # Consume the LLM-free devman (drops the home.packages claude/codex clash).
      inputs.devman.follows = "devman";
    };

    # devman with codex/claude dropped from devman-tools (nix-apps single-owns
    # the LLM CLIs). Local branch until pushed; then repoint to github main.
    devman = {
      url = "git+file:///home/andrew/Documents/Projects/devman?ref=no-llm-tools";
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

    # ── framework laptop (desktop tier) inputs ────────────────────────────────
    # The wayland shell HM modules (niri/noctalia/walker/workspace-groups). Its
    # own inputs (noctalia/walker/nirinit/niri-sidebar-ext) stay at nix-desktop's
    # lock; only nixpkgs is unified.
    # NOTE: temporarily pinned to a LOCAL branch that commits the noctalia
    # wallpaper asset (untracked on github main → missing store path at eval).
    # Repoint to github main once nix-desktop commits+pushes the wallpaper.
    nix-desktop = {
      url = "git+file:///home/andrew/Documents/Projects/nix-desktop?ref=migration-wallpaper-asset";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # GUI application bundles (browsers/creative/office/media/llmCli/notes/
    # editors). Local-only repo (no GitHub remote yet) — consumed over git+file
    # from main. It owns the obsidian + claude-code pins; those must NOT follow.
    nix-apps = {
      url = "git+file:///home/andrew/Documents/Projects/nix-apps?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Session-restore daemon (services.nirinit) — GAP-C owner for the graphical
    # tier. Also provides the niri startup restore the dotfiles' base.kdl calls.
    nirinit = {
      url = "github:amaanq/nirinit";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Personal sandbox-fork host module (/cortex/fornix btrfs). Framework only.
    fornix-host.url = "github:Bullish-Design/fornix?dir=nix/fornix-host";
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

        # The framework laptop — migration target. Walks the UI ladder to the
        # desktop tier: base (minimal) → terminal → graphical → desktop. Built
        # (not switched) alongside ~/.dotfiles until parity is proven.
        # NOTE: declarative kitty + zellij config is NOT yet covered — the pinned
        # nix-terminal (main) has no kitty/zellij module (those live on the
        # wave2 branch's nix-terminal.* split). Deferred to the fleet-wide
        # nix-terminal namespace reconciliation.
        framework = mkMachine "framework" [ profiles.minimal profiles.terminal profiles.graphical profiles.desktop ];
      };
    };
}
