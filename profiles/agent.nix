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
    # codex: the other host-level agent CLI. Previously reached the box via
    # devman-tools, which no longer bundles the LLM CLIs (nix-apps single-owns
    # them on the desktop tier); the agent profile is codex's proper owner for
    # headless hosts worked in over SSH.
    codex
    # zellij: terminal multiplexer so long agent runs survive an SSH drop
    # (network switch / laptop sleep) — reattach with `zellij attach`. Also the
    # fleet-standard multiplexer, a precursor to the zelligate workspace daemon.
    zellij
  ];

  # The binary lives read-only in the Nix store, so its self-updater can never
  # succeed — silence it. Updates happen by bumping the nixpkgs input + rebuild.
  environment.variables.DISABLE_AUTOUPDATER = "1";
}
