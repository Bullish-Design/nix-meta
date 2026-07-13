inputs:
{ config, pkgs, lib, ... }:

let
  inherit (inputs) nix-terminal home-manager;

  # Username SSOT — read the base tier's value (set per-host in the machine
  # module) so this profile never hardcodes a user and composes onto whatever
  # host imports it.
  username = config.nixos-core.base.username;
in
{
  # nix-terminal is Home-Manager config, so ensure HM is wired. On the server
  # the machine module already imports this + sets the toggles for the zelligate
  # user service; importing again is dedup-safe, and mkDefault means the machine's
  # plain values win with no conflict. On a future host that uses this profile
  # standalone, these provide a working default.
  imports = [ home-manager.nixosModules.home-manager ];

  home-manager = {
    useGlobalPkgs = lib.mkDefault true;
    useUserPackages = lib.mkDefault true;

    # First switch on a box with hand-written dotfiles (~/.zshrc, ~/.zcompdump):
    # back them up as <file>.hm-backup instead of aborting the rebuild. Without
    # this, `nixos-rebuild switch` fails with "would be clobbered". Your existing
    # ~/.gitconfig is untouched regardless — enableGit is off below.
    backupFileExtension = lib.mkDefault "hm-backup";

    users.${username} = { ... }: {
      imports = [ nix-terminal.homeManagerModules.terminal ];

      # Set as a default so a machine that pins its own stateVersion (the server
      # does) wins without a conflicting-definition error.
      home.stateVersion = lib.mkDefault "25.05";

      programs.nix-terminal = {
        enable = true;

        # Git config is intentionally left to your hand-maintained ~/.gitconfig.
        # Flip to true (and let backupFileExtension archive the old file) if you
        # want nix-terminal to own git declaratively instead.
        enableGit = false;

        # corePackages defaults to the modern CLI kit (ripgrep/fd/bat/eza/fzf/…).
        # extraPackages is where day-to-day terminal apps for this box live —
        # start with yazi; developer-only tooling belongs in developer.nix.
        extraPackages = with pkgs; [
          yazi
        ];

        zsh = {
          enable = true;
          theme = "starship";

          aliases = {
            ll = "eza -lah --icons";
            la = "eza -A --icons";
            l = "eza --icons";
            ".." = "cd ..";
            "..." = "cd ../..";
            cat = "bat";
            gst = "git status";
            gd = "git diff";
            gc = "git commit";
            gp = "git push";
            gl = "git log --oneline --graph --decorate";
            # nix-nvim ships the launcher as `nv` (only the wrapper is on PATH,
            # not a bare `nvim`), so point the muscle-memory aliases at it.
            vim = "nv";
            vi = "nv";
          };

          # yazi's cd-on-quit wrapper: `y` opens the file manager and, on exit,
          # cd's the shell to wherever you navigated. This is what makes yazi a
          # navigation tool rather than just a viewer.
          extraConfig = ''
            function y() {
              local tmp cwd
              tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
              yazi "$@" --cwd-file="$tmp"
              IFS= read -r -d "" cwd < "$tmp"
              [ -n "$cwd" ] && [ "$cwd" != "$PWD" ] && builtin cd -- "$cwd"
              rm -f -- "$tmp"
            }
          '';
        };

        atuin = {
          enable = true;
          searchMode = "fuzzy";
          style = "auto";
          autoSync = false;
        };
      };

      # loci is on (nix-nvim's default). It used to be force-disabled here
      # because the stack pulled loci-core (private → github: 404 headless) and
      # knappy (a laptop `path:`); both are now fetched over git+ssh
      # (loci-core@57c83f4, knappy via git+ssh, shipped in loci.nvim@v0.1.2), so
      # the server resolves the full loci stack with its authorized SSH key.
    };
  };
}
