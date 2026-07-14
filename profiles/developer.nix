inputs:
{ config, lib, pkgs, ... }:

let
  inherit (inputs) home-manager nix-terminal shellij;

  cfg = config.nix-meta.developer;
  username = config.nixos-core.base.username;
  homeDir = "/home/${username}";
in
{
  imports = [ home-manager.nixosModules.home-manager ];

  options.nix-meta.developer = {
    enable = lib.mkEnableOption "the shared developer workflow";

    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        gh
        nodejs
        python3
        # Gitman owns its Python/pyjutsu runtime through its own pinned devenv;
        # keep the launcher available from every developer profile.
        devenv
      ];
      description = "Developer tools installed for the configured base user, including Gitman's devenv launcher.";
    };

    nixbuild = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable nixbuild for the configured developer user.";
      };

      outputDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Directory for nixbuild logs; null derives a user-relative default.";
      };
    };

    repoman = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable repoman for the configured developer user.";
      };

      baseDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Repository checkout root; null derives ~/Documents/Projects.";
      };

      accounts = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
        description = "Per-host repoman account and repository policy.";
      };

      useSsh = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use SSH remotes for repoman operations.";
      };

      maxConcurrent = lib.mkOption {
        type = lib.types.int;
        default = 5;
        description = "Maximum concurrent repoman git operations.";
      };

      timeout = lib.mkOption {
        type = lib.types.int;
        default = 300;
        description = "Repoman operation timeout in seconds.";
      };
    };
  };

  config = lib.mkMerge [
    # Importing the profile opts a host in by default; a host can still set this
    # false explicitly when sharing a profile list with a non-developer machine.
    { nix-meta.developer.enable = lib.mkDefault true; }

    (lib.mkIf cfg.enable {
      # This is deliberately independent of `terminal`: it can merge with that
      # profile's HM user module without re-owning shell, git, or terminal config.
      home-manager = {
        useGlobalPkgs = lib.mkDefault true;
        useUserPackages = lib.mkDefault true;
        backupFileExtension = lib.mkDefault "hm-backup";

        users.${username} = { ... }: {
          imports = [
            nix-terminal.homeManagerModules.nixbuild
            nix-terminal.homeManagerModules.repoman
            shellij.homeManagerModules.default
          ];

          home.stateVersion = lib.mkDefault "25.05";

          # Keep this separate from `programs.nix-terminal`: developer tooling
          # remains additive even when a host chooses a different shell profile.
          home.packages = cfg.packages;

          programs.shellij = {
            enable = true;
            projectsRoot = "${homeDir}/Documents/Projects";
          };

          programs.nixbuild = {
            enable = cfg.nixbuild.enable;
            outputDir = if cfg.nixbuild.outputDir == null
              then "${homeDir}/.nixbuild-logs"
              else cfg.nixbuild.outputDir;
            defaultAction = "test";
            keepLast = 10;
            enableRecording = true;
          };

          programs.repoman = {
            enable = cfg.repoman.enable;
            baseDir = if cfg.repoman.baseDir == null
              then "${homeDir}/Documents/Projects"
              else cfg.repoman.baseDir;
            accounts = cfg.repoman.accounts;
            useSsh = cfg.repoman.useSsh;
            maxConcurrent = cfg.repoman.maxConcurrent;
            timeout = cfg.repoman.timeout;
          };
        };
      };
    })
  ];
}
