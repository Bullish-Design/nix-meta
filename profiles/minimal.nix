inputs:
{ pkgs, ... }:

let
  inherit (inputs) nixos-core;
in
{
  imports = [
    nixos-core.nixosModules.base
  ];

  # system.stateVersion is per-host (tracks each box's install) — set in the
  # machine module, not this shared profile.

  nixos-core.base = {
    enable = true;
    enableFlakes = true;
    experimentalFeatures = [ "nix-command" "flakes" ];
    systemPackages = with pkgs; [
      git
    ];
  };

  # Deduplicate identical store files during a quiet, predictable window. This
  # applies to every machine that composes the minimal base profile.
  nix.optimise = {
    automatic = true;
    dates = [ "02:00" ];
  };

  # Automounting for removable drives (USB SSDs, etc.) on every machine.
  # udisks2 is the daemon desktop environments talk to for plug-and-play mounts.
  services.udisks2.enable = true;

  # udisks2 only acts when something asks it to. On a headless machine no
  # desktop session does, so devmon watches udev and drives udisks2 itself.
  # It mounts new media under /run/media/$USER and unmounts on removal.
  # devmon is a systemd *user* service: the target user needs linger enabled
  # to catch hotplug events with no active login session.
  services.devmon.enable = true;
}
