inputs:
{ config, ... }:

let
  username = config.nixos-core.base.username;
in
{
  # The devman automation plane, machine side (devman CONCEPT.md §4).
  #
  # One Dagu control plane per machine, as a systemd USER service. Every
  # workflow step runs a developer's own `devenv` in a developer's own checkout,
  # so the service needs that developer's $HOME, Nix profile, ~/.cache, git
  # credentials and SSH agent. A system service would need all of that plumbed
  # explicitly.
  #
  # This profile authors nothing. The whole machine interface is devman's
  # module, and every value below is a decision this host makes rather than a
  # default it repeats.
  imports = [ inputs.devman.nixosModules.default ];

  services.devman-dagu = {
    enable = true;

    # Without lingering, the user manager exists only while andrew is logged in,
    # so the plane is not running on a box nobody has SSH'd into — and, less
    # obviously, activation cannot restart it either, because
    # `switch-to-configuration` reaches exactly the users logind lists (devman
    # finding C7). This host already has Linger=yes for andrew; stating it here
    # makes it a property of the configuration rather than of the machine's
    # accumulated state.
    lingerUsers = [ username ];

    # Everything else is devman's default and is deliberately not repeated:
    # ports 8080 and 50055, the five queues (light 4, normal 2, heavy 1, gpu 1,
    # exclusive 1), DAGU_HOME at %h/.local/share/dagu, the registry at
    # $HOME/.local/share/devman, seven-day history retention, and the profile
    # roots prepended to the unit's PATH. Restating a default here would be a
    # second place to keep in sync with the flake.
    #
    # The two ports are the only thing this host shares with anything else. Both
    # were free when this was written; a second Dagu fails loudly on the
    # coordinator with `bind: address already in use`.
  };
}
