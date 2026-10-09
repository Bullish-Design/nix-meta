{
  description = "Modular NixOS configurations with centralized settings";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Pi changes rapidly and is used by Paseo as an external CLI. Keep its
    # package evaluation on an independently locked nixpkgs commit, so routine
    # system nixpkgs bumps cannot change the Pi binary unexpectedly.
    #
    # Pinned independently from system nixpkgs. This exact revision carries the
    # latest stable pi-coding-agent (1.0.4, released 2026-10-05), so Pi can be
    # updated or rolled back without coupling it to routine system package bumps.
    pi-nixpkgs.url = "github:NixOS/nixpkgs/e7439b6b14ad3cc35d05608ebca9bce01a25f5f8";

    # Pin to a released devenv version. This pin is what profiles/developer.nix
    # installs. It used to be declared here and ignored, while `pkgs.devenv`
    # from the system nixpkgs supplied the actual binary — three declarations
    # for one name (023-toolchain P4).
    #
    # DELIBERATELY NOT following this flake's nixpkgs, and the one input that is
    # allowed to carry its own. devenv pins a curated nixpkgs
    # (cachix/devenv-nixpkgs) and publishes binaries only against it, including
    # its own Nix fork and the nixd / nixf language servers. Overriding that
    # nixpkgs changes every derivation hash, so no cache can serve them and Nix
    # itself gets compiled locally — about a thousand derivations.
    #
    # That is not merely slow, it does not build. On nixos-unstable as of
    # 2026-10-05, cachix/nix fails to compile: meson's unity build emits
    # `#include <.../src/libstore/build/build/build-log.cc>` — a duplicated path
    # segment, because src/libstore/meson.build lists 'build/build-log.cc' while
    # the build directory is also named `build`. Nix's own meson files never
    # enable unity, so the flag arrives with the newer nixpkgs.
    #
    # Left alone, devenv resolves entirely from cache: 4 paths, 85.5 MiB, zero
    # builds. The cost is a second nixpkgs in flake.lock. Pay it here.
    devenv.url = "github:cachix/devenv/v2.4.0";

    nixos-core.url = "git+https://github.com/Bullish-Design/nixos-core.git?ref=main";

    # The shared RepoMan command closure (Vendomat). profiles/developer.nix puts
    # its bin on the login shell's PATH, replacing the mutable venv used by the
    # retired machine bootstrap path.
    #
    # Pinned to an exact source revision so "which repoman is on my PATH" stays
    # answerable while the shared toolchain release is prepared.
    # NO `inputs.nixpkgs.follows`. Vendomat pins the same nixpkgs the devenv stack uses,
    # and that pin is what makes the closure shared: a devenv consumer and this login
    # shell must resolve the SAME store paths for the same commands. Making vendomat
    # follow the system nixpkgs forks the closure in two — same source, same version,
    # different build — which is the duplication this whole design removes.
    vendomat.url = "git+https://github.com/Bullish-Design/vendomat?rev=d5a90f0aff97224b34e9bc2647e56b44cbf790d5";

    # Project 039 (repoman half): the repoman devenv meta-module, machine-installed.
    # This ONE pin replaces the twenty-three per-repository `devenv.yaml` pins the
    # measurement found (2026-09-15). `nixosModules.default` installs
    # `/run/current-system/sw/share/repoman/module/devenv.nix`, and each repository's
    # central `devenv.local.nix` imports it from that stable path instead of
    # declaring its own `repoman` input.
    # The project manifest supplies each repository's manager roster. The shared closure
    # is now the only provider for the pure-CLI managers.
    repoman.url = "git+https://github.com/Bullish-Design/repoman?ref=refs/tags/v0.9.2";

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
    #
    # Consumed from the LOCAL working copy, pinned to a TAG. `git+file:` keeps
    # the encrypted store on this box. The tag ensures Nix sees committed files
    # only, so an in-progress edit cannot enter a rebuild. Bump the tag to adopt
    # a new secret, exactly like the vendomat/repoman/devman pins above.
    nix-secrets = {
      url = "git+file:///home/andrew/Documents/Projects/nix-secrets?ref=refs/tags/v0.1.4";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Phase C: the workspace daemon (zelligate) is layered onto the server.
    # zelligate is a private repo, pulled over the SSH input form (same
    # convention as nix-secrets above), NOT a laptop `path:`. It exposes the two
    # modules the server imports directly (nix-meta authors nothing): a
    # Home-Manager user-service module and a system-level Tailscale-Serve module.
    # DISABLED 2026-08-01: input commented out. The server's zelligate import
    # was already disabled 2026-07-18 (devenv scan store churn); uncomment the
    # input + the server import/blocks together to restore Phase C.
    # zelligate = {
    #   url = "git+ssh://git@github.com/Bullish-Design/zelligate.git?ref=main";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };

    # Agent CLIs (Claude Code, Codex) — consumed by profiles/agent.nix, the sole
    # installation point for agent tooling. sadjow's flakes wrap the upstream npm
    # packages with pinned Nix builds; pinned at ref=main, resolved to concrete
    # revs in flake.lock. devman (via nix-terminal) declares the same inputs, so
    # the lock dedupes both paths onto the same nodes.
    claude-code = {
      url = "github:sadjow/claude-code-nix?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    codex-cli = {
      url = "github:sadjow/codex-cli-nix?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The interactive terminal environment (zsh/atuin/starship/nvim/tmux) — the
    # rich shell you get over SSH and inside zelligate web terminals. The tower
    # is a host worked IN directly, which is exactly this flake's purpose, so it
    # belongs in the server set. Fetched as a git input (public repo, like
    # nixos-core) — NOT the old laptop `path:` that broke the on-box build.
    nix-terminal = {
      url = "git+file:///home/andrew/Documents/Projects/nix-terminal?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.devman.inputs.devenv.follows = "devenv";
    };

    # Shared Hindsight service and declarative Claude/Codex/Pi wiring. This is
    # a direct composer input: nix-paseo does not depend on Mnemonix.
    mnemonix = {
      url = "git+file:///home/andrew/Documents/Projects/mnemonix?ref=refs/tags/v0.2.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Shellij is developed on this server and supplies the Home Manager module
    # for durable project workbenches. Use Git source filtering so generated
    # devenv state is never copied into the Nix store as part of this input.
    # DISABLED 2026-08-01: input commented out (WIP repo kept the lock dirty,
    # which breaks reproducible rebuilds). The developer profile's import +
    # programs.shellij block are disabled alongside; re-lock cleanly when the
    # workbench is ready.
    # shellij = {
    #   url = "git+file:///home/andrew/Documents/Projects/shellij";
    #   inputs.nixpkgs.follows = "nixpkgs";
    #   inputs.home-manager.follows = "home-manager";
    # };

    # Atuin includes native output capture (introduced by PR #3510). Release
    # 18.22 replaced its old Semantic gRPC API with native `atuin output`
    # storage/search; the separate atuout archiver still probes the old API.
    # Consume Atuin's flake (packages.atuin, built via fenix) so client, daemon,
    # and sync server share one upstream build.
    # Keep the Home Manager package.version overrides in profiles/terminal.nix
    # and machines/server.nix in sync with this release tag.
    atuin = {
      url = "github:atuinsh/atuin/v18.23.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # atuout: durable archiver for Atuin's native command-output captures. Local
    # Git source (like shellij) so generated devenv/mypy state never enters the
    # store. Exposes packages.atuout + homeManagerModules.atuout, so terminal.nix
    # authors only the glue (pty-proxy init ordering + daemon toggle).
    atuout = {
      url = "git+file:///home/andrew/Documents/Projects/atuout";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # pytuin: typed Python SDK + diagnostics for the box's atuin/atuout stack
    # (`pytuin status` / `pytuin doctor`; KV + recordings library). Local Git
    # source like atuout. `follows` dedupe nixpkgs and re-use nix-meta's atuout
    # and home-manager lock nodes, so the pytuin package builds against the SAME
    # nixpkgs + atuout rev the host already runs — one atuout build, no runtime
    # drift. Two consumption paths, deliberately separate:
    #   - package only on the CLIENT side. terminal.nix (via nix-terminal +
    #     atuout) stays the single owner of programs.atuin/atuout and the zsh
    #     init ordering, so programs.pytuin (the HM client module) is NOT
    #     enabled — it would define sync_address twice and conflict.
    #   - nixosModules.pytuin-server on the SERVER side (machines/server.nix),
    #     which owns services.atuin + its Tailscale Serve unit. That module
    #     touches nothing nix-terminal configures.
    pytuin = {
      url = "git+file:///home/andrew/Documents/Projects/pytuin";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.atuout.follows = "atuout";
      inputs.home-manager.follows = "home-manager";
    };

    # fornix sandbox substrate. Provisions the btrfs cortex volume that fornix
    # forks sandboxes on (loopback image at /cortex/fornix, mounted
    # user_subvol_rm_allowed and owned by andrew). Private GitHub repo, and the
    # module lives in a subdir with its own flake.nix, so consume it as a local
    # path input rather than a git+ssh URL.
    fornix-host.url = "path:/home/andrew/Documents/Projects/fornix/nix/fornix-host";

    # Native inference service modules. Use the local Git source form so Nix
    # snapshots only Git-tracked source files; a raw path input would recursively
    # copy generated deployment environments (currently tens of gigabytes) into
    # the store on every content change.
    # DISABLED 2026-08-01: input commented out; the server's imports + service
    # blocks are also disabled. The repo moved to feature branch
    # project22-llama-cpp-fork-reorg (100+ commits ahead of the last lock);
    # re-lock deliberately before restoring.
    # structured-agents = {
    #   url = "git+file:///home/andrew/Documents/Projects/structured-agents-v2";
    # };

    # Personal SilverBullet server (notes PKM) published over Tailscale Serve at
    # https://server.<tailnet>.ts.net/notes. A self-contained flake exporting one
    # NixOS module; runtime packages resolve from this system's pkgs, so `follows`
    # keeps it on our nixpkgs (its own nixpkgs input is only for its checks).
    # Private repo → SSH input form (same convention as nix-secrets/zelligate), so
    # no GitHub token is needed to fetch it. Its own nixpkgs input is only for its
    # checks; `follows` keeps the fleet on one nixpkgs.
    silverbullet-server = {
      url = "git+ssh://git@github.com/Bullish-Design/silverbullet-server.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The devman automation plane. One flake exposes both interfaces at one
    # revision: `nixosModules.default` is this machine's Dagu service (consumed
    # by profiles/devman.nix), and the SAME rev's `modules/` directory is what
    # every adopted repository imports from its own devenv.yaml. That is the
    # whole anti-drift argument — the machine and the repos cannot disagree
    # about queue names, the registry layout or `DEVMAN_PROJECT_DIR`, because
    # there is one version of all three.
    #
    # `git+file:` records `rev` and `narHash` in flake.lock, just as
    # `git+https:` does, but it sees committed files only. Use `path:` for the
    # one repository under active edit; every other local consumer is pinned
    # with `git+file:`. A `github:` input hits the GitHub API rate limit on every
    # evaluation. (devman FINDINGS.md B4, corrected; CONCEPT.md §3.2.)
    #
    # The Project 038 link work that once needed a bare-rev pin is now in the
    # published tag: `v0.7.0` carries the independent link adapter and its
    # machine-installed link-only module (038 Stages 16-18), so this machine
    # gets `devman-link` on its PATH and `/share/devman/link-module.nix`
    # through `services.devman-dagu.installLinkAdapter`, which defaults to
    # true. A rollback is a pin to an earlier tag.
    # `follows` here only removes a duplicate nixpkgs node from the lock. The
    # NixOS module takes `pkgs` from this machine and never reads devman's own
    # nixpkgs input, which serves that flake's `packages` and `checks` alone.
    devman = {
      url = "git+https://github.com/Bullish-Design/devman?ref=refs/tags/v0.7.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The argentic overlay bridge: a pi agent on the SilverBullet notes surface,
    # reached through SilverBullet's own proxy. Local git source like pytuin —
    # committed files only, and the revision is recorded in flake.lock.
    #
    # A separate service from silverbullet-server on purpose. The bridge runs pi
    # as the person who owns the notes, because pi reads its credentials from
    # that account's ~/.pi/agent/auth.json, while SilverBullet runs as its own
    # service user. One unit could not be both.
    argentic = {
      url = "git+file:///home/andrew/Documents/Projects/argentic";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Native inference service module. The repository is not a flake, so keep
    # it as a source input and import its NixOS module through `inputs`.
    inferference = {
      url = "git+ssh://git@github.com/Bullish-Design/inferference.git?ref=main";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

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
        server = mkMachine "server" [ profiles.minimal profiles.terminal profiles.developer profiles.gpu-compute profiles.agent profiles.secrets profiles.backup profiles.devman profiles.mnemonix ];
      };

      checks.${system}.atuin-server-runtime =
        let
          serverConfig = self.nixosConfigurations.server.config;
          serverPackage = serverConfig.services.pytuin.server.package;
          clientPackage = serverConfig.home-manager.users.andrew.programs.atuin.package;
        in
        assert serverPackage.outPath == clientPackage.outPath;
        pkgs.runCommand "atuin-server-runtime" { } ''
          client_version="$(${pkgs.coreutils}/bin/env -i \
            HOME="$TMPDIR" \
            PATH=${lib.makeBinPath [ pkgs.coreutils ]} \
            ${clientPackage}/bin/atuin --version)"
          server_version="$(${pkgs.coreutils}/bin/env -i \
            HOME="$TMPDIR" \
            PATH=${lib.makeBinPath [ pkgs.coreutils ]} \
            ${serverPackage}/bin/atuin-server --version)"

          echo "client_version=$client_version"
          echo "server_version=$server_version"

          test "$client_version" = "atuin 18.23.0 (NO_GIT)"
          test "$server_version" = "atuin-server 18.23.0"
          touch "$out"
        '';
    };
}
