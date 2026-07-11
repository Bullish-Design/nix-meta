inputs:
{ pkgs, ... }:

{
  # Agent tooling for working ON the box over SSH: Claude Code, installed
  # declaratively from nixpkgs (unfree — covered by nixos-core.base.allowUnfree).
  # This is the host-level CLI; per-repo toolchains still come from each repo's
  # devenv. Stacked on top of `minimal` like gpu-compute, so it's trivial to
  # promote into nixos-core.base (fleet-wide) or drop later.
  environment.systemPackages = with pkgs; [
    claude-code
  ];

  # The binary lives read-only in the Nix store, so its self-updater can never
  # succeed — silence it. Updates happen by bumping the nixpkgs input + rebuild.
  environment.variables.DISABLE_AUTOUPDATER = "1";
}
