inputs:
{
  # Only `minimal` is wired for the server bring-up. `developer` and `gui` remain
  # on disk as dormant skeleton (they still reference the old `nixos-core.common`
  # namespace + the nix-terminal input); re-export them once they're ported to the
  # `nixos-core.base` module.
  minimal = import ./minimal.nix inputs;
}
