inputs:
{ config, lib, pkgs, ... }:

let
  username = config.nixos-core.base.username;

  # Everything the forge owns lives under one mount. machines/server.nix mounts
  # nvme1n1 here; see the "forge drive" block there for why that disk and not
  # the system disk.
  forgeRoot = "/srv/forge";

  # The tailnet FQDN this box already publishes SilverBullet and Atuin on. The
  # forge joins the same perimeter rather than opening a second one.
  tailnetHost = "server.tail770f47.ts.net";

  # Loopback port. 3000 is SilverBullet, 8080/50055 are Dagu, 8790 is the
  # argentic bridge, 8888 is Atuin. 3001 and 2222 were free when this was
  # written; a collision fails loudly with `bind: address already in use`.
  httpPort = 3001;
  sshPort = 2222;
in
{
  # ── The local forge: Forgejo ────────────────────────────────────────────────
  #
  # This box is the upstream for every repository worked on here. GitHub becomes
  # a downstream push mirror, not the source of truth. Two things motivate that:
  #
  #   1. CI/CD iteration speed. Changing a workflow and learning whether it works
  #      is a push-and-wait loop on GitHub Actions. Forgejo Actions runs the same
  #      workflow syntax against a runner on this machine, so the loop is
  #      seconds. The ~9 repositories here that carry their own workflows port
  #      across unchanged.
  #
  #   2. Cross-repository release orchestration. The flake inputs in flake.nix
  #      make these repositories a dependency graph — agentman feeds vendomat,
  #      vendomat feeds nix-meta. Driving "a tag landed upstream, so relock and
  #      re-verify the dependents" needs cross-repository triggers, which GitHub
  #      expresses only through personal access tokens and repository_dispatch.
  #      A post-receive hook on a forge you own expresses it directly.
  #
  # The forge is NOT the source of truth for flake inputs. See the READ PATH note
  # below — that split is deliberate and load-bearing.
  services.forgejo = {
    enable = true;

    # Both under the forge mount, so the whole forge is one directory to back up
    # and one filesystem to move. The NixOS default puts stateDir in
    # /var/lib/forgejo, which would put the authoritative repositories back on
    # the system disk and defeat the point.
    stateDir = "${forgeRoot}/state";
    repositoryRoot = "${forgeRoot}/repositories";

    # PostgreSQL is already on this box for Atuin and agentman. A third database
    # in the existing v17 cluster costs nothing; a second database engine would.
    database = {
      type = "postgres";
      createDatabase = true;
    };

    # Model weights and datasets are the reason. Without LFS every large blob
    # becomes a pack object and repacking a repository grows unbounded.
    lfs.enable = true;

    # Same perimeter argument as SilverBullet and Atuin: bound to loopback,
    # exposed on no interface, published by Tailscale Serve. The tailnet ACL is
    # the whole boundary.
    httpAddress = "127.0.0.1";
    inherit httpPort;

    settings = {
      server = {
        DOMAIN = tailnetHost;
        ROOT_URL = "https://${tailnetHost}/forge/";

        # Forgejo's own SSH server rather than the host sshd. The host sshd
        # alternative needs a `git` account whose authorized_keys Forgejo
        # rewrites, which puts a service's generated file inside the account
        # that guards this machine. A separate daemon on its own port keeps
        # that blast radius inside the forge.
        START_SSH_SERVER = true;
        SSH_LISTEN_HOST = "127.0.0.1";
        SSH_LISTEN_PORT = sshPort;
        SSH_PORT = sshPort;
        SSH_DOMAIN = tailnetHost;
        LFS_START_SERVER = true;
      };

      # Single-user forge. Registration stays shut; accounts are created with
      # `forgejo admin user create` as the forgejo user.
      service = {
        DISABLE_REGISTRATION = true;
        REQUIRE_SIGNIN_VIEW = true;
      };

      # Forgejo Actions. DEFAULT_ACTIONS_URL = github makes `uses: actions/...`
      # in a workflow resolve to github.com/actions/..., which is what lets the
      # existing GitHub workflows run here without edits.
      actions = {
        ENABLED = true;
        DEFAULT_ACTIONS_URL = "github";
      };

      # Push mirroring to GitHub. This is what keeps GitHub a real second copy
      # rather than a stale one. ENABLED covers push mirrors; the interval is
      # the floor Forgejo will accept when a repository asks for one.
      mirror = {
        ENABLED = true;
        DEFAULT_INTERVAL = "8h";
        MIN_INTERVAL = "10m";
      };

      repository = {
        DEFAULT_BRANCH = "main";
        # gitman lands into trunk and pushes a fast-forward. Nothing here opens
        # a pull request against itself, so the merge-style defaults are noise.
        DEFAULT_PUSH_CREATE_PRIVATE = true;
      };

      # The forge holds every credential-adjacent repository on this box,
      # nix-secrets included. Keep its own logs quiet about request bodies.
      log.LEVEL = "Warn";
    };
  };

  # ── READ PATH: flake inputs stay resolvable with the forge stopped ──────────
  #
  # Forgejo stores each repository as an ordinary bare git repository at
  # ${forgeRoot}/repositories/<owner>/<repo>.git. Nothing about that layout needs
  # the service running to read it.
  #
  # That matters because a NixOS module cannot depend on a service defined by the
  # configuration it is evaluating. If flake.nix fetched its inputs over
  # https://${tailnetHost}/forge/..., then building this machine would require
  # the forge, and building the forge would require this machine. A fresh install
  # could never bootstrap.
  #
  # So the two paths are split:
  #
  #   WRITE  ssh://forgejo@127.0.0.1:2222/andrew/<repo>.git
  #          gitman's `origin`. Goes through Forgejo, so hooks, permissions,
  #          Actions and mirroring all fire.
  #
  #   READ   git+file://${forgeRoot}/repositories/andrew/<repo>.git
  #          What flake.nix may use for inputs. Plain filesystem, no daemon, no
  #          network, works during `nixos-install` with nothing running.
  #
  # Keep flake inputs on github.com until the forge has proven itself; the read
  # path above is what makes moving them a later choice rather than a trap.
  environment.sessionVariables.FORGE_REPO_ROOT = "${forgeRoot}/repositories";

  # ── CI runner ───────────────────────────────────────────────────────────────
  #
  # `native:host` runs each job directly on this machine instead of in a
  # container. Docker is available here, but a containerised runner cannot see
  # /nix/store, so every nix-based job would rebuild the world per run. Native
  # execution keeps the store, and with it the only build cache that matters.
  #
  # The cost is that jobs are not isolated from the host. That is acceptable for
  # a single-user forge whose only workflows are this user's own.
  services.gitea-actions-runner.instances.forge = {
    enable = true;
    name = "server-native";
    url = "http://127.0.0.1:${toString httpPort}";
    tokenFile = config.sops.secrets."forgejo-runner-token".path;
    labels = [ "native:host" ];

    # The runner builds a PATH from this list only. A workflow step that calls
    # something absent here fails with "command not found" even though the
    # binary is installed system-wide.
    hostPackages = with pkgs; [
      bash
      coreutils
      curl
      findutils
      git
      gnugrep
      gnused
      gnutar
      gzip
      jq
      nix
      openssh
      wget
      xz
    ];

    settings = {
      # 4 physical cores on this Xeon, shared with inferference-router,
      # SilverBullet, Atuin and argentic. Two concurrent jobs is the ceiling
      # before interactive work on the box degrades.
      runner.capacity = 2;
      cache = {
        enable = true;
        dir = "${forgeRoot}/cache/actions";
      };
      container.network = "host";
    };
  };

  # ── CPU containment ─────────────────────────────────────────────────────────
  #
  # Without this, one llama.cpp build saturates all 8 threads and the box stops
  # answering. CI must never be able to take the machine down; it is the least
  # important thing running here.
  systemd.slices.forge-ci = {
    description = "Forge CI runner — capped share of an 8-thread host";
    sliceConfig = {
      CPUQuota = "400%"; # half the threads
      CPUWeight = 20; # yields to every default-weight service
      IOWeight = 20;
      MemoryHigh = "24G";
      MemoryMax = "32G";
    };
  };

  systemd.services."gitea-runner-forge".serviceConfig = {
    Slice = "forge-ci.slice";
    # The runner's working tree and the repositories it clones from are both on
    # the forge mount. Starting before it mounts produces an empty state dir
    # that Forgejo then initialises in the wrong place.
    RequiresMountsFor = [ forgeRoot ];
  };

  systemd.services.forgejo.serviceConfig.RequiresMountsFor = [ forgeRoot ];

  # ── Mirror verification ─────────────────────────────────────────────────────
  #
  # Autonomy from GitHub is only real when the mirror provably works. A push
  # mirror that has been silently failing converts "GitHub is my backup" into
  # "GitHub was my backup". This compares each mirrored repository's trunk
  # against the GitHub remote and writes a report; it changes nothing.
  systemd.services.forge-mirror-check = {
    description = "Compare forge trunk against the GitHub mirror for every repository";
    serviceConfig = {
      Type = "oneshot";
      User = "forgejo";
      Group = "forgejo";
      Slice = "forge-ci.slice";
      RequiresMountsFor = [ forgeRoot ];
    };
    path = with pkgs; [ git openssh coreutils gnugrep ];
    script = ''
      set -u
      root="${forgeRoot}/repositories"
      stale=0
      for repo in "$root"/*/*.git; do
        [ -d "$repo" ] || continue
        name="$(basename "$(dirname "$repo")")/$(basename "$repo" .git)"
        remote="$(git -C "$repo" remote get-url --push origin 2>/dev/null || true)"
        case "$remote" in
          *github.com*) ;;
          *) continue ;;
        esac
        local_sha="$(git -C "$repo" rev-parse refs/heads/main 2>/dev/null || true)"
        remote_sha="$(git -C "$repo" ls-remote "$remote" refs/heads/main 2>/dev/null | cut -f1)"
        if [ -z "$local_sha" ] || [ -z "$remote_sha" ]; then
          echo "UNKNOWN  $name (local='$local_sha' remote='$remote_sha')"
          stale=$((stale + 1))
        elif [ "$local_sha" != "$remote_sha" ]; then
          echo "BEHIND   $name  forge=$local_sha github=$remote_sha"
          stale=$((stale + 1))
        else
          echo "ok       $name"
        fi
      done
      echo "--- $stale repositories not mirrored to GitHub trunk ---"
      # Exit non-zero so `systemctl status` and the journal both surface it.
      [ "$stale" -eq 0 ]
    '';
  };

  systemd.timers.forge-mirror-check = {
    description = "Weekly forge/GitHub mirror comparison";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon 04:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };

  # The interactive user reads the forge's repositories directly for flake
  # inputs and for `git clone` of a local path, so it needs traverse rights on
  # the repository root. Forgejo creates that tree 0750 forgejo:forgejo.
  users.users.${username}.extraGroups = [ "forgejo" ];

  # Reachable from the tailnet only. 22 and 8077 are already open there; the
  # forge's HTTP and SSH stay on loopback and are published by Tailscale Serve,
  # so neither port is added to any interface.
  environment.systemPackages = [ pkgs.forgejo ];
}
