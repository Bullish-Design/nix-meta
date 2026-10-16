inputs:
{ config, ... }:

let
  username = config.nixos-core.base.username;
in
{
  # The devman workflow plane, machine side (devman 047, CONCEPT.md §10).
  #
  # One Dagu control plane per machine, as two systemd USER services:
  # `devman-dagu` (the server and scheduler) and `devman-watch` (the watcher).
  # Every workflow step runs the developer's own `devenv` in the developer's own
  # checkout, so the services need that user's $HOME, Nix profile and credentials.
  # Home Manager owns them. Home Manager still runs as a NixOS module here, so
  # the module goes into `home-manager.users.${username}`. Vendomat phase 4
  # (standalone home) will move this one import.
  #
  # The module installs the wrapped `devman` command and the `dagu` command. It
  # reads the overlay at ~/.config/devman and writes compiled files, run logs and
  # events under ~/.local/state/devman. Every option keeps its default: ports 8080
  # and 50055, six queues, and DAGU_HOME at ~/.local/share/dagu.
  home-manager.users.${username} = {
    imports = [ inputs.devman.homeManagerModules.default ];
    services.devman.enable = true;
  };

  # Home Manager cannot set linger. Without it, the user manager runs only while
  # the user is logged in, so the plane stops on a box nobody has SSH'd into.
  # machines/server.nix sets the same value; two equal definitions merge.
  users.users.${username}.linger = true;
}
