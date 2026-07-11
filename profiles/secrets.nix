inputs:
{ config, ... }:

let
  inherit (inputs) nix-secrets;
in
{
  imports = [
    # The sops-nix wrapper module (provider). Brings sops-nix transitively —
    # nix-meta never imports or pins sops-nix directly (nix-secrets owns it).
    nix-secrets.nixosModules.secrets
  ];

  # Enable the secrets provider. The age identity is the box's own SSH host key
  # (module default ageKeySource = /etc/ssh/ssh_host_ed25519_key); the encrypted
  # store + recipients live inside the nix-secrets flake. sops-nix decrypts each
  # declared secret to /run/secrets/<name> at activation.
  nix-secrets.secrets.enable = true;

  # Incremental activation: only tailscale-auth-key has material + a consumer
  # today. Grow this per phase (attic → nix-cache, github → CI/push, hf → vLLM)
  # as real secrets are provisioned. The full naming SSOT stays in nix-secrets.
  nix-secrets.secrets.activeNames = [ "tailscale-auth-key" ];

  # Consume tailscale-auth-key for declarative tailnet re-auth. The provider owns
  # the secret *declaration*; nixos-core.base owns the *service* wiring — the
  # consumer only names the secret and reads its path (RUNBOOK §5).
  nixos-core.base.tailscale.authKeyFile =
    config.sops.secrets."tailscale-auth-key".path;
}
