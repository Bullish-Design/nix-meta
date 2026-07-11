inputs:
{
  # Only `minimal` + `gpu-compute` are wired for the server. `developer` and `gui`
  # remain on disk as dormant skeleton (they still reference the old
  # `nixos-core.common` namespace + the nix-terminal input); re-export them once
  # they're ported to the `nixos-core.base` module.
  minimal = import ./minimal.nix inputs;

  # Headless NVIDIA CUDA layer (Phase C) — stacked on top of `minimal`.
  gpu-compute = import ./gpu-compute.nix inputs;

  # Agent tooling (Claude Code) for on-box SSH work — stacked on `minimal`.
  agent = import ./agent.nix inputs;

  # Declarative secrets (sops-nix): the box decrypts with its own SSH host key.
  secrets = import ./secrets.nix inputs;
}
