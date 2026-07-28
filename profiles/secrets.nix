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

  # Incremental activation: only secrets with encrypted material are enabled
  # here. The full naming SSOT stays in nix-secrets.
  nix-secrets.secrets.activeNames = [
    "tailscale-auth-key"
    # "deepseek-api-key"  # DISABLED: key material not yet provisioned in secrets.yaml
  ];

  # Pi runs both in interactive shells and as a Paseo subprocess.  Keep the
  # decrypted source readable only by its service/user, then render the form
  # systemd expects without ever placing the value in the Nix store.
  # DISABLED: deepseek-api-key material not yet provisioned in secrets.yaml.
  # nix-secrets.secrets.secrets."deepseek-api-key" = {
  #   owner = config.nixos-core.base.username;
  #   group = "users";
  #   mode = "0400";
  #   restartUnits = [ "paseo.service" ];
  # };

  # sops.templates."paseo-deepseek.env" = {
  #   owner = config.nixos-core.base.username;
  #   group = "users";
  #   mode = "0400";
  #   content = ''
  #     DEEPSEEK_API_KEY=${config.sops.placeholder."deepseek-api-key"}
  #   '';
  # };

  # Consume tailscale-auth-key for declarative tailnet re-auth. The provider owns
  # the secret *declaration*; nixos-core.base owns the *service* wiring — the
  # consumer only names the secret and reads its path (RUNBOOK §5).
  nixos-core.base.tailscale.authKeyFile =
    config.sops.secrets."tailscale-auth-key".path;
}
