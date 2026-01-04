inputs:
{ pkgs, ... }:

let
  inherit (inputs) nixos-core nix-terminal home-manager;
in
{
  imports = [
    nixos-core.nixosModules.common
    home-manager.nixosModules.home-manager
  ];

  # System configuration
  system.stateVersion = "25.05";

  # Configure nixos-core
  nixos-core.common = {
    enableFlakes = true;
    experimentalFeatures = [ "nix-command" "flakes" ];
    systemPackages = with pkgs; [
      git
      vim
    ];
  };

  # Home Manager configuration
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    users.nixos = { ... }: {
      imports = [
        nix-terminal.homeManagerModules.terminal
        nix-terminal.homeManagerModules.nixbuild
      ];

      home.stateVersion = "25.05";
      programs.home-manager.enable = true;

      # Configure nix-terminal
      programs.nix-terminal = {
        enable = true;

        # Core packages
        corePackages = with pkgs; [
          tree
          jq
          ripgrep
          fd
          bat
          eza
          fzf
          htop
          curl
          wget
        ];

        extraPackages = with pkgs; [
          nodejs
          python3
        ];

        # Git settings
        enableGit = true;
        gitDefaultBranch = "main";
        gitPullRebase = true;

        # Zsh configuration
        zsh = {
          enable = true;
          theme = "starship";
          enableAutosuggestions = true;
          enableSyntaxHighlighting = true;
          enableCompletion = true;

          # Define all aliases
          aliases = {
            # Navigation
            ll = "ls -lah";
            la = "ls -A";
            l = "ls -CF";
            ".." = "cd ..";
            "..." = "cd ../..";

            # Git shortcuts
            gst = "git status";
            gd = "git diff";
            gc = "git commit";
            gp = "git push";
            gl = "git log --oneline --graph --decorate";

            # Tools
            grep = "grep --color=auto";
            vim = "nvim";
          };

          historySize = 50000;
          extraConfig = ''
            # Custom zsh config here
          '';
        };

        # Atuin configuration
        atuin = {
          enable = true;
          searchMode = "fuzzy";
          style = "auto";
          autoSync = false;
        };

        # Starship prompt (using defaults, can override)
        # starshipSettings = { ... };
      };

      # Configure nixbuild
      programs.nixbuild = {
        enable = true;
        outputDir = "/home/nixos/.nixbuild-logs";
        keepLast = 10;
        enableRecording = true;
        defaultAction = "test";
      };
    };
  };
}
