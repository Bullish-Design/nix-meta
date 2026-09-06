# NixOS module for the reviewed 150 W soft PowerPlay table on both MI25 cards.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.inferference-mi25-power-table;
  applier = "${cfg.repoDir}/ci/runner/amdgpu-soft-power-table.sh";
  serviceFor = card:
    let
      serviceName = lib.replaceStrings [ ":" "." ] [ "-" "-" ] card.bdf;
    in
    {
      name = "inferference-mi25-power-table-${serviceName}";
      value = {
        description = "Apply the reviewed 150 W soft PowerPlay table to ${card.bdf}";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-modules-load.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = ''
            ${pkgs.bash}/bin/bash ${applier} --bdf ${card.bdf} --table ${card.table} \
              --expected-current-sha ${card.baselineSha} \
              --expected-target-sha ${card.targetSha}
          '';
          RemainAfterExit = true;
        };
      };
    };
in
{
  options.services.inferference-mi25-power-table = {
    enable = lib.mkEnableOption "the reviewed 150 W MI25 soft PowerPlay table";

    repoDir = lib.mkOption {
      type = lib.types.path;
      default = /home/andrew/Documents/Projects/inferference;
      description = "Inferference checkout containing the table applier.";
    };

    cards = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule ({ ... }: {
        options = {
          bdf = lib.mkOption { type = lib.types.str; description = "PCI BDF of the card."; };
          table = lib.mkOption { type = lib.types.path; description = "Reviewed 150 W table."; };
          baselineSha = lib.mkOption {
            type = lib.types.str;
            default = "87adbd7dec9615e6455fed3ef31b468f5c49063e40f27061f672b06b057c7784";
          };
          targetSha = lib.mkOption {
            type = lib.types.str;
            default = "13309ea2cc3c288f4acb105dd0e8a33a3fb712423d6febf3f401c1720d7f4db2";
          };
        };
      }));
      default = [
        { bdf = "0000:19:00.0"; table = ./mi25-card0-150.pp_table; }
        { bdf = "0000:67:00.0"; table = ./mi25-card0-150.pp_table; }
      ];
      description = "Both MI25 cards receive the reviewed 150 W table by default.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services = lib.listToAttrs (map serviceFor cfg.cards);
  };
}
