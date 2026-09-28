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
    "subconscious-api-key"
    # "deepseek-api-key"  # DISABLED: key material not yet provisioned in secrets.yaml
    # "forgejo-runner-token"  # DISABLED: material not yet provisioned in secrets.yaml
  ];

  nix-secrets.secrets.secrets."subconscious-api-key" = {
    owner = config.nixos-core.base.username;
    group = "users";
    mode = "0400";
    restartUnits = [ "paseo.service" ];
  };

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

  # The Forgejo Actions runner registration token (profiles/forge.nix). Generate
  # it once the forge is up, as the forgejo user:
  #
  #   forgejo --config /srv/forge/state/custom/conf/app.ini \
  #     actions generate-runner-token
  #
  # then put that value in nix-secrets' secrets.yaml and enable the name above.
  # The runner re-registers from the token on first start and then holds its own
  # credential in its state directory, so rotating the token does not invalidate
  # a registered runner.
  #
  # DISABLED: forgejo-runner-token material not yet provisioned in secrets.yaml.
  # nix-secrets.secrets.secrets."forgejo-runner-token" = {
  #   owner = "gitea-runner";
  #   group = "gitea-runner";
  #   mode = "0400";
  #   restartUnits = [ "gitea-runner-forge.service" ];
  # };

  # Consume tailscale-auth-key for declarative tailnet re-auth. The provider owns
  # the secret *declaration*; nixos-core.base owns the *service* wiring — the
  # consumer only names the secret and reads its path (RUNBOOK §5).
  nixos-core.base.tailscale.authKeyFile =
    config.sops.secrets."tailscale-auth-key".path;
}
