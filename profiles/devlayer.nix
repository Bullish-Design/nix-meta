inputs:
{ config, lib, pkgs, ... }:

let
  cfg = config.nix-meta.devlayer;
  user = config.nixos-core.base.username;
  group = config.users.users.${user}.group;
  bin = "${pkgs.coreutils}/bin";
  cmp = "${pkgs.diffutils}/bin/cmp";
in
{
  options.nix-meta.devlayer.pointerPath = lib.mkOption {
    type = lib.types.str;
    default = "/home/${user}/.local/state/devlayer/current.nix";
    description = ''
      Path of the devlayer pointer file. Every overlay devenv.local.nix reads
      it through ~/.config/devman/common/devlayer.nix. The file must be a
      regular file, never a symlink (vendomat project 22 R12, R14).
    '';
  };

  # Vendomat project 22 OI-08 (evidence W9, W10). devenv tracks an import only
  # when its last path part is not a symlink. The old import of
  # /run/current-system/sw/share/devman/link-module.nix is a symlink, so a
  # repository kept a stale module. This step writes a regular pointer file
  # that names the module in the new system. It writes only when the content
  # changes. Phase 4 moves this step to Home Manager activation.
  config.system.activationScripts.devlayerPointer = {
    deps = [ "users" ];
    text = ''
      (
        ptr=${lib.escapeShellArg cfg.pointerPath}
        dir="$(${bin}/dirname "$ptr")"
        mod="$(${bin}/readlink -e "$systemConfig/sw/share/devman/link-module.nix" || true)"
        if [ -z "$mod" ]; then
          echo "warning: devlayerPointer: no devman link module in $systemConfig; pointer not written" >&2
        elif [ -L "$ptr" ] || { [ -e "$ptr" ] && [ ! -f "$ptr" ]; }; then
          echo "warning: devlayerPointer: $ptr is not a regular file; left alone" >&2
        elif [ ! -d "$(${bin}/dirname "$dir")" ]; then
          echo "warning: devlayerPointer: no parent of $dir; pointer not written" >&2
        else
          ${bin}/install -d -m 0755 -o ${user} -g ${group} "$dir"
          tmp="$(${bin}/mktemp "$dir/.current.nix.XXXXXX")"
          printf '%s\n%s\n' \
            '# Written by the devlayer pointer step. Do not edit. Vendomat project 22 R12, R14.' \
            "import $mod" > "$tmp"
          if [ -f "$ptr" ] && ${cmp} -s "$tmp" "$ptr"; then
            ${bin}/rm -f "$tmp"
          else
            ${bin}/chmod 0644 "$tmp"
            ${bin}/chown ${user}:${group} "$tmp"
            ${bin}/mv -f "$tmp" "$ptr"
          fi
        fi
      )
    '';
  };
}
