inputs:
{ config, pkgs, lib, ... }:

let
  inherit (inputs) nix-terminal home-manager;

  # Username SSOT — read the base tier's value (set per-host in the machine
  # module) so this profile never hardcodes a user and composes onto whatever
  # host imports it.
  username = config.nixos-core.base.username;

  # With systemd socket activation (HM's atuin module sets systemd_socket = true
  # on NixOS) the daemon binds the socket *systemd* hands it — `%t/atuin.sock`,
  # i.e. $XDG_RUNTIME_DIR/atuin.sock — while atuin's own client (pty-proxy) and
  # atuout read `[daemon].socket_path` from config.toml to reach it. Pin
  # socket_path to that same runtime path so daemon, pty-proxy and atuout all
  # agree; pointing it at ~/.local/share breaks history recording (pty-proxy
  # can't connect) and atuout harvesting with it. NixOS assigns uids at
  # activation (the `uid` option is null until then), so fall back to the
  # standard first-user uid 1000.
  atuinSocketPath =
    let uid = config.users.users.${username}.uid or null;
    in "/run/user/${toString (if uid == null then 1000 else uid)}/atuin.sock";
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

    users.${username} = { config, pkgs, lib, ... }: {
      imports = [
        nix-terminal.homeManagerModules.terminal
        inputs.atuout.homeManagerModules.atuout
      ];

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
        # extraPackages is where day-to-day terminal apps for this box live.
        # Television is a TUI fuzzy finder, so it works directly in SSH and
        # zelligate terminal sessions; developer-only tooling belongs in
        # developer.nix.
        extraPackages = with pkgs; [
          yazi
          television
          superfile
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

      # ── atuout: durable Atuin command-output capture ──────────────────────
      # atuout harvests Atuin's native OSC-133 output captures into a per-user
      # SQLite store. It requires a capture-capable atuin daemon (>= 18.18.0-beta.2)
      # and a shell wrapped by `atuin pty-proxy`. nix-terminal enables atuin above
      # with the modern history widget; here we add the three things atuout needs.

      # Swap the nixpkgs atuin (18.16.1, no capture service) for the flake build
      # that ships PR #3510's Semantic gRPC service. atuin's own atuin.nix sets
      # `name` but no `version`; HM's atuin module reads `package.version`
      # (versionAtLeast for the socket dir), so add it back via overrideAttrs.
      programs.atuin.package =
        inputs.atuin.packages.${pkgs.stdenv.hostPlatform.system}.atuin.overrideAttrs
          (_: { version = "18.18.0-beta.2"; });

      # Run the atuin daemon as a systemd user service (HM manages it). atuout
      # talks to it over the Unix socket below (see `atuinSocketPath` above).
      programs.atuin.daemon.enable = true;
      programs.atuin.settings.daemon.socket_path = atuinSocketPath;

      # pty-proxy init MUST run before atuout's harvest hook. Its emitted code
      # `exec`s the shell into the proxy PTY (setting ATUIN_PTY_PROXY_ACTIVE) and
      # re-sources zshrc; atuout's init (mkOrder 1500, from its HM module) then
      # fires on that second pass. mkBefore lands this at the very top of the
      # interactive init. This is separate from — and complements — the normal
      # `atuin init zsh` history widget that enableZshIntegration still emits.
      programs.zsh.initContent = lib.mkBefore ''
        if command -v atuin >/dev/null 2>&1; then
          eval "$(atuin pty-proxy init zsh)"
        fi
      '';

      # atuout package + single reconciler systemd user service + its zsh eval.
      programs.atuout.enable = true;

      # loci is on (nix-nvim's default). It used to be force-disabled here
      # because the stack pulled loci-core (private → github: 404 headless) and
      # knappy (a laptop `path:`); both are now fetched over git+ssh
      # (loci-core@57c83f4, knappy via git+ssh, shipped in loci.nvim@v0.1.2), so
      # the server resolves the full loci stack with its authorized SSH key.
    };
  };
}
