# System backups (restic) — Phase 0 of the local depot and release bus.
#
# A profile, not a machine file: a backup policy is not machine specific. The
# machine supplies one thing, the target disk, through `nix-meta.backup`.
#
# WHAT THIS PROFILE REFUSES TO DO
#
# It never creates a repository. `initialize = false` is deliberate. An
# automatic `restic init` against an absent mount writes a fresh, empty
# repository onto the root filesystem and reports success, which is worse than
# any failure. Initialization is an operator step, run once, against a mount
# that has been proved.
#
# It never starts a backup it cannot trust. Every run begins with a preflight
# check that fails the unit before restic opens the repository. See `preflight`
# below for the five conditions.
#
# It never fails silently. There is no proven remote notification channel on
# this host, so the signal is local and persistent: a marker file under
# `/var/lib/restic-backup-status`, a journal error, `wall` to live sessions, a
# line on the next interactive login, and a health timer that fails when the
# last success gets too old.
#
# WHAT IT DOES NOT PROVE
#
# A file-level backup of `/var/lib` copies a LIVE PostgreSQL cluster and a LIVE
# Docker volume. Neither copy is a valid application backup. `postgres.enable`
# adds a logical `pg_dumpall` stream for the database; the Mnemonix Hindsight
# volume has no equivalent yet. Both limits are recorded in
# `.scratch/projects/01-phase-0-restic-backups/DESIGN.md`.
inputs:
{ config, lib, pkgs, ... }:

let
  cfg = config.nix-meta.backup;

  secretName = "restic-password";

  # `profiles/secrets.nix` lists which canonical names this host activates, and
  # nix-secrets drops an active name that has no encrypted material yet. So the
  # secret may be absent at eval time. Reading
  # `config.sops.secrets."restic-password".path` unconditionally would then be
  # an evaluation ERROR, not a warning — the same trap `hasDeepSeekKey` avoids
  # in profiles/secrets.nix. Gate on presence and keep the rebuild working.
  hasPassword = config.sops.secrets ? ${secretName};
  passwordFile = config.sops.secrets.${secretName}.path or "/run/secrets/${secretName}";

  # Both switches must be on. `enable` is the operator's decision that a proved
  # disk is in the machine; `hasPassword` is the fact that sops will deliver the
  # key. Either one missing means no units at all.
  active = cfg.enable && hasPassword;

  statusDir = "/var/lib/restic-backup-status";
  jobName = "system";

  resticBin = "${cfg.package}/bin/restic";

  # ── Preflight ──────────────────────────────────────────────────────────────
  #
  # Runs before restic touches the repository, in both the backup unit and the
  # check unit. It reads RESTIC_* from the unit environment, so the two units
  # cannot drift apart on repository, password file, or cache location.
  #
  # The last step is a plain `restic unlock`. Without `--remove-all` it removes
  # only STALE locks — a lock whose owning process is gone. An active lock held
  # by a concurrent operation survives, and the restic command that follows
  # fails loudly instead of racing it.
  preflight = pkgs.writeShellScript "restic-preflight-${jobName}" ''
    set -euo pipefail

    fail() {
      echo "restic preflight: $*" >&2
      exit 1
    }

    mount=${lib.escapeShellArg cfg.mountPoint}
    repo=${lib.escapeShellArg cfg.repository}
    cache=${lib.escapeShellArg cfg.cacheDir}
    pwfile=${lib.escapeShellArg passwordFile}

    # 1. The backup disk must be mounted. `nofail` in machines/server.nix means
    #    an absent drive leaves a plain empty directory on the root filesystem.
    ${pkgs.util-linux}/bin/mountpoint -q "$mount" \
      || fail "$mount is not a mount point. The backup disk is absent."

    # 2. The mount must not BE the root filesystem. Condition 1 already implies
    #    this, so treat a disagreement as a sign that something is wrong rather
    #    than as a redundant test: the root filesystem is 95% full and a restic
    #    repository there would fill it.
    root_dev="$(${pkgs.coreutils}/bin/stat -c %d /)"
    mount_dev="$(${pkgs.coreutils}/bin/stat -c %d "$mount")"
    [ "$root_dev" != "$mount_dev" ] \
      || fail "$mount resolves to the root filesystem (device $root_dev)."

    # 3. The repository must already exist. This profile never initializes one.
    [ -d "$repo" ] || fail "$repo does not exist. Initialize it as an operator step."
    [ -f "$repo/config" ] || fail "$repo holds no restic config file."

    # 4. The password file must be present and tight. sops-nix writes it to
    #    /run/secrets at activation; a wrong owner or mode means something else
    #    produced it.
    [ -f "$pwfile" ] || fail "$pwfile is absent. sops did not decrypt ${secretName}."
    pwmeta="$(${pkgs.coreutils}/bin/stat -c '%U:%G %a' "$pwfile")"
    [ "$pwmeta" = "root:root 400" ] \
      || fail "$pwfile is $pwmeta; expected root:root 400."

    # 5. The cache must live on the backup disk. The NixOS restic module points
    #    RESTIC_CACHE_DIR at /var/cache, which is on the nearly full root
    #    filesystem. This profile overrides it; verify the override took.
    ${pkgs.coreutils}/bin/install -d -m 0700 "$cache"
    cache_dev="$(${pkgs.coreutils}/bin/stat -c %d "$cache")"
    [ "$cache_dev" = "$mount_dev" ] \
      || fail "cache $cache is not on $mount."

    # 6. Clear a stale lock, never an active one.
    ${resticBin} unlock
  '';

  # ── Failure signal ─────────────────────────────────────────────────────────
  #
  # One script, reached by `OnFailure` from every unit in this profile. It keeps
  # the marker short and world-readable so the login hook can print it, and
  # keeps the journal excerpt root-only because it names paths under /home.
  #
  # restic never prints the repository password, and this script never reads the
  # password file, so neither output carries secret material.
  failureScript = pkgs.writeShellScript "restic-backup-failure" ''
    set -euo pipefail
    unit="''${1:-unknown.service}"
    now="$(${pkgs.coreutils}/bin/date -Is)"
    result="$(${pkgs.systemd}/bin/systemctl show -p Result --value "$unit" 2>/dev/null || echo unknown)"
    code="$(${pkgs.systemd}/bin/systemctl show -p ExecMainStatus --value "$unit" 2>/dev/null || echo unknown)"

    ${pkgs.coreutils}/bin/install -d -m 0755 ${statusDir}

    ${pkgs.coreutils}/bin/cat > ${statusDir}/last-failure <<EOF
    unit=$unit
    time=$now
    result=$result
    exit=$code
    journal=${statusDir}/last-failure.log
    EOF
    ${pkgs.coreutils}/bin/chmod 0644 ${statusDir}/last-failure

    ${pkgs.systemd}/bin/journalctl -u "$unit" -n 60 --no-pager -o cat \
      > ${statusDir}/last-failure.log 2>/dev/null || true
    ${pkgs.coreutils}/bin/chmod 0600 ${statusDir}/last-failure.log

    ${pkgs.util-linux}/bin/logger -t restic-backup -p daemon.err \
      "$unit failed (result=$result exit=$code). See ${statusDir}/last-failure."

    ${pkgs.util-linux}/bin/wall \
      "restic backup: $unit FAILED at $now (result=$result exit=$code). Details in ${statusDir}/last-failure." \
      2>/dev/null || true
  '';

  # Records a success and clears the failure marker. Nothing else clears it.
  successScript = pkgs.writeShellScript "restic-backup-success" ''
    set -euo pipefail
    kind="''${1:?usage: restic-backup-success <backup|check>}"
    ${pkgs.coreutils}/bin/install -d -m 0755 ${statusDir}
    {
      echo "epoch=$(${pkgs.coreutils}/bin/date +%s)"
      echo "time=$(${pkgs.coreutils}/bin/date -Is)"
    } > "${statusDir}/last-success-$kind"
    ${pkgs.coreutils}/bin/chmod 0644 "${statusDir}/last-success-$kind"
    ${pkgs.coreutils}/bin/rm -f ${statusDir}/last-failure ${statusDir}/last-failure.log
  '';

  # Fails when the newest successful backup is older than `maxSuccessAge`, or
  # when there has never been one. A backup that stopped running is the failure
  # mode a per-run alert cannot see.
  healthScript = pkgs.writeShellScript "restic-backup-health" ''
    set -euo pipefail
    marker=${statusDir}/last-success-backup
    limit=${toString cfg.maxSuccessAge}

    if [ ! -f "$marker" ]; then
      echo "restic health: no successful backup has ever been recorded." >&2
      exit 1
    fi

    epoch="$(${pkgs.gnused}/bin/sed -n 's/^epoch=//p' "$marker")"
    case "$epoch" in
      ''' | *[!0-9]*) echo "restic health: $marker is unreadable." >&2; exit 1 ;;
    esac

    age=$(( $(${pkgs.coreutils}/bin/date +%s) - epoch ))
    if [ "$age" -gt "$limit" ]; then
      echo "restic health: the last successful backup is $age s old; the limit is $limit s." >&2
      exit 1
    fi
    echo "restic health: last successful backup $age s ago."
  '';

  # The one shared set of systemd knobs. Every unit here needs the same mount,
  # the same state directory, and the same failure hook.
  commonUnit = {
    unitConfig.RequiresMountsFor = [ cfg.mountPoint ];
    onFailure = [ "restic-backup-failure@%n.service" ];
  };
in
{
  options.nix-meta.backup = {
    enable = lib.mkEnableOption ''
      scheduled restic system backups.

      Turn this on only when all of the following hold, because the units it
      creates assume them: a healthy disk is connected and mounted at
      `mountPoint`, a restic repository already exists at `repository`, and
      `restic-password` has encrypted material in nix-secrets AND is listed in
      `nix-secrets.secrets.activeNames`. Missing material alone does not break
      the rebuild — the profile warns and creates nothing
    '';

    package = lib.mkPackageOption pkgs "restic" { };

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/wd_green1";
      description = ''
        The mount point of the backup disk. The machine sets this option
        explicitly; the default here only names the current target.
        `/mnt/wd_green1` (the WD Caviar Green) is the current target, chosen
        because its restic repository already exists. A WD Re disk, or the
        planned NAS, is the upgrade path once one is connected. The units
        take a hard systemd dependency on this mount, and the preflight
        check proves it is mounted and is not the root filesystem.
      '';
    };

    repository = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.mountPoint}/restic";
      defaultText = lib.literalExpression ''"''${mountPoint}/restic"'';
      description = ''
        The restic repository path. It must already exist: this profile sets
        `initialize = false` so no unit can create one.
      '';
    };

    cacheDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.mountPoint}/restic-cache";
      defaultText = lib.literalExpression ''"''${mountPoint}/restic-cache"'';
      description = ''
        Where restic keeps its cache. It belongs on the backup disk. The NixOS
        module's default is `/var/cache/restic-backups-<name>`, which is on the
        root filesystem — 95% full on this host as of 2026-10-01.
      '';
    };

    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/home/andrew" "/etc" "/var/lib" ];
      description = "The source paths to back up.";
    };

    exclude = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        # Rebuildable caches and build trees. These drop roughly 150 GB.
        "/home/andrew/.cache"
        "**/.devenv"
        "**/target"
        "**/.venv"
        "**/node_modules"
        "**/.worktrees"
        # Docker layer and build storage. Images are rebuildable from their
        # sources; the build cache alone was 36.37 GB on 2026-10-01. Named
        # volumes under /var/lib/docker/volumes stay IN the backup.
        "/var/lib/docker/overlay2"
        "/var/lib/docker/buildkit"
      ];
      description = "restic exclude patterns.";
    };

    time = lib.mkOption {
      type = lib.types.str;
      default = "02:30";
      description = ''
        The daily `OnCalendar` time for the backup. The timer is persistent, so
        a run missed while the host was off starts after boot.
      '';
    };

    checkTime = lib.mkOption {
      type = lib.types.str;
      default = "Sun 04:00";
      description = "The weekly `OnCalendar` time for the repository check.";
    };

    readDataSubset = lib.mkOption {
      type = lib.types.str;
      default = "10%";
      description = ''
        The fraction of pack files the weekly check re-reads. A structural
        check alone does not detect bit rot, and this disk is old.
      '';
    };

    maxSuccessAge = lib.mkOption {
      type = lib.types.int;
      default = 36 * 60 * 60;
      description = ''
        How old the newest successful backup may be, in seconds, before the
        health timer fails. The default gives a daily schedule one missed run
        of slack.
      '';
    };

    postgres = {
      enable = lib.mkEnableOption ''
        a logical PostgreSQL backup, streamed into the same repository by
        `pg_dumpall`.

        UNPROVEN as of 2026-10-02. Copying the live cluster files under
        /var/lib/postgresql is NOT a database backup, so this job exists; but
        it has not been run on this host, because doing so needs root. Run
        `systemctl start restic-backups-postgres.service` and confirm the
        snapshot before you depend on it, and do not exclude
        /var/lib/postgresql until you have
      '';

      time = lib.mkOption {
        type = lib.types.str;
        default = "02:00";
        description = ''
          The daily `OnCalendar` time for the dump. It is before
          `nix-meta.backup.time` so the dump snapshot is never newer than the
          file snapshot that shares the repository.
        '';
      };
    };
  };

  config = lib.mkMerge [
    # ── The profile is on but the key has not arrived ───────────────────────
    #
    # Say so loudly. A backup profile that is silently inert is the failure
    # this whole phase exists to prevent.
    (lib.mkIf (cfg.enable && !hasPassword) {
      warnings = [
        ''
          nix-meta.backup is enabled but the secret '${secretName}' has no
          entry in config.sops.secrets, so NO backup units were created. Add
          encrypted material for '${secretName}' in nix-secrets, then list the
          name in nix-secrets.secrets.activeNames (profiles/secrets.nix).
        ''
      ];
    })

    (lib.mkIf active {
      # ── The backup job ────────────────────────────────────────────────────
      services.restic.backups.${jobName} = {
        inherit (cfg) package paths exclude repository;

        # The decrypted path only. The value never reaches the Nix store or a
        # unit file, and never appears in an argument or an environment value.
        passwordFile = passwordFile;

        # This profile never creates a repository. See the header.
        initialize = false;

        # The module would append `restic check` to the backup unit's own
        # ExecStart. Keep the check a separate unit so a failed check does not
        # read as a failed backup, and so it can re-read data on its own
        # schedule.
        runCheck = false;

        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];

        timerConfig = {
          OnCalendar = cfg.time;
          # Run after boot if the scheduled time was missed.
          Persistent = true;
          # The host also runs Dagu, inferference-router, SilverBullet, Atuin
          # and argentic on 4 cores. Spread the start.
          RandomizedDelaySec = "20m";
          AccuracySec = "1m";
        };

        # preStart, ahead of everything else the module puts there.
        backupPrepareCommand = ''
          #!${pkgs.runtimeShell}
          exec ${preflight}
        '';
      };

      # ── Unit wiring the restic module does not provide ────────────────────
      systemd.services = {
        "restic-backups-${jobName}" = lib.mkMerge [
          commonUnit
          {
            environment.RESTIC_CACHE_DIR = lib.mkForce cfg.cacheDir;
            serviceConfig = {
              StateDirectory = "restic-backup-status";
              StateDirectoryMode = "0755";
              ExecStartPost = "${successScript} backup";
              # The disk is slow and the first run copies ~107 GiB.
              TimeoutStartSec = "infinity";
              IOSchedulingClass = "idle";
              Nice = 10;
            };
          }
        ];

        # ── The weekly repository check ─────────────────────────────────────
        #
        # It copies the backup unit's RESTIC_* variables, so repository,
        # password file and cache can never drift between the two.
        #
        # RESTIC_* only. The whole attrset also carries PATH, which
        # system/boot/systemd.nix defines for every unit — copying it across
        # is a conflicting definition of `environment.PATH`.
        "restic-check-${jobName}" = lib.mkMerge [
          commonUnit
          {
            description = "restic repository check (${jobName})";
            environment = lib.filterAttrs
              (n: _: lib.hasPrefix "RESTIC_" n)
              config.systemd.services."restic-backups-${jobName}".environment;
            serviceConfig = {
              Type = "oneshot";
              StateDirectory = "restic-backup-status";
              StateDirectoryMode = "0755";
              ExecStartPre = "${preflight}";
              ExecStart =
                "${resticBin} check --read-data-subset=${cfg.readDataSubset}";
              ExecStartPost = "${successScript} check";
              TimeoutStartSec = "infinity";
              IOSchedulingClass = "idle";
              Nice = 10;
              PrivateTmp = true;
            };
          }
        ];

        # ── The health check ────────────────────────────────────────────────
        #
        # No RequiresMountsFor: this unit must still run and still fail when
        # the backup disk is gone. That is the case it exists to catch.
        "restic-backup-health" = {
          description = "Check that a recent restic backup succeeded";
          onFailure = [ "restic-backup-failure@%n.service" ];
          serviceConfig = {
            Type = "oneshot";
            StateDirectory = "restic-backup-status";
            StateDirectoryMode = "0755";
            ExecStart = "${healthScript}";
          };
        };

        # ── The failure recorder ────────────────────────────────────────────
        #
        # Templated on the failed unit's name, which systemd passes through %n.
        # It carries no OnFailure of its own, so it cannot recurse.
        "restic-backup-failure@" = {
          description = "Record and announce the failure of %i";
          serviceConfig = {
            Type = "oneshot";
            StateDirectory = "restic-backup-status";
            StateDirectoryMode = "0755";
            ExecStart = "${failureScript} %i";
          };
        };
      };

      systemd.timers = {
        "restic-check-${jobName}" = {
          description = "Weekly restic repository check (${jobName})";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.checkTime;
            Persistent = true;
            RandomizedDelaySec = "30m";
            AccuracySec = "1m";
          };
        };

        "restic-backup-health" = {
          description = "Daily restic backup freshness check";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "09:00";
            Persistent = true;
            RandomizedDelaySec = "10m";
          };
        };
      };

      # ── The login warning ─────────────────────────────────────────────────
      #
      # One `test -f` on an interactive shell. It prints the marker, which holds
      # no secret material, and points at the journal excerpt.
      environment.interactiveShellInit = ''
        if [ -f ${statusDir}/last-failure ]; then
          printf '\033[1;31m!! restic backup FAILED\033[0m — %s\n' \
            "${statusDir}/last-failure" >&2
          ${pkgs.gnused}/bin/sed -n 's/^/   /p' ${statusDir}/last-failure >&2
        fi
      '';

      # The operator wrapper the restic module generates is `restic-system`. It
      # carries the repository, the password file and the cache directory, so a
      # manual command cannot contradict the service.
      #
      # No separate global restic package: a bare `restic` with no RESTIC_*
      # set is how an operator reaches the wrong repository.
      assertions = [
        {
          assertion = cfg.repository != "" && !(lib.hasPrefix "/mnt/shared" cfg.repository);
          message = ''
            nix-meta.backup.repository must not live under /mnt/shared. That
            drive holds 130 GB of unadjudicated data and is Phase F work.
          '';
        }
        {
          assertion = lib.hasPrefix cfg.mountPoint cfg.repository;
          message = ''
            nix-meta.backup.repository (${cfg.repository}) must be under
            nix-meta.backup.mountPoint (${cfg.mountPoint}), otherwise
            RequiresMountsFor guards the wrong filesystem.
          '';
        }
        {
          assertion = lib.hasPrefix cfg.mountPoint cfg.cacheDir;
          message = ''
            nix-meta.backup.cacheDir (${cfg.cacheDir}) must be under
            nix-meta.backup.mountPoint (${cfg.mountPoint}). The root filesystem
            has no room for a restic cache.
          '';
        }
      ];
    })

    # ── The logical PostgreSQL dump ─────────────────────────────────────────
    #
    # Its own mkMerge branch on purpose. `services.restic.backups.postgres =
    # lib.mkIf cond {...}` would still CREATE the `postgres` attribute when
    # cond is false, and the restic module then asserts on a job with neither
    # paths nor command. Gating the whole config set creates no attribute.
    #
    # pg_dumpall must run as the `postgres` OS user: the generated pg_hba.conf
    # carries `local all postgres peer map=postgres`, and the default identMap
    # maps only `postgres postgres postgres`. root is NOT mapped, so root
    # cannot connect as the postgres role. `runuser` drops to that user for the
    # dump while restic keeps running as root to write the repository.
    (lib.mkIf (active && cfg.postgres.enable) {
      services.restic.backups.postgres = {
        inherit (cfg) package repository;
        passwordFile = passwordFile;
        initialize = false;
        runCheck = false;

        command = [
          "${pkgs.util-linux}/bin/runuser"
          "-u"
          "postgres"
          "--"
          "${config.services.postgresql.package}/bin/pg_dumpall"
          "-h"
          "/run/postgresql"
          "--clean"
          "--if-exists"
        ];

        extraBackupArgs = [ "--stdin-filename" "pg_dumpall.sql" ];

        timerConfig = {
          OnCalendar = cfg.postgres.time;
          Persistent = true;
          RandomizedDelaySec = "10m";
          AccuracySec = "1m";
        };

        backupPrepareCommand = ''
          #!${pkgs.runtimeShell}
          exec ${preflight}
        '';
      };

      systemd.services."restic-backups-postgres" = lib.mkMerge [
        commonUnit
        {
          environment.RESTIC_CACHE_DIR = lib.mkForce cfg.cacheDir;
          after = [ "postgresql.service" ];
          serviceConfig = {
            StateDirectory = "restic-backup-status";
            StateDirectoryMode = "0755";
            ExecStartPost = "${successScript} postgres";
            TimeoutStartSec = "6h";
            IOSchedulingClass = "idle";
            Nice = 10;
          };
        }
      ];

      assertions = [
        {
          assertion = config.services.postgresql.enable;
          message = ''
            nix-meta.backup.postgres.enable needs services.postgresql.enable.
          '';
        }
      ];
    })
  ];
}
