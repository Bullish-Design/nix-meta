inputs:
{ config, lib, ... }:

let
  inherit (inputs) nix-secrets;

  # True once deepseek-api-key has material in the encrypted store. Everything
  # that reads its placeholder is gated on this, so a rebuild succeeds while the
  # secret is still unprovisioned.
  hasDeepSeekKey = config.sops.secrets ? "deepseek-api-key";
  hasAtticSigningKey = config.sops.secrets ? "attic-signing-key";
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
    "attic-signing-key"
    "subconscious-api-key"
    # Consumed by Pi and Paseo. Mnemonix Hindsight deliberately does not receive
    # this credential: its retain and reflect calls go to a local model, either
    # the loopback Inferference router or vLLM on tower, never to DeepSeek.
    # `warnOnMissingKeys` is true, so until the material lands in nix-secrets
    # this name is dropped with an eval warning instead of failing the rebuild.
    "deepseek-api-key"
  ];

  # Ownership overrides for the secrets this host consumes. One definition:
  # two attribute paths under `nix-secrets.secrets.secrets` in one module body
  # would be a duplicate-key error.
  #
  # Both entries are UNCONDITIONAL, and must stay that way. This option feeds
  # nix-secrets' `mkSopsSecret`, which produces `sops.secrets` — so gating it on
  # `hasDeepSeekKey` (which reads `sops.secrets`) is an infinite recursion.
  # An override for a secret that has no material is inert: `effectiveNames`
  # never looks it up.
  nix-secrets.secrets.secrets = {
    "attic-signing-key" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "atticd.service" ];
    };

    "subconscious-api-key" = {
      owner = config.nixos-core.base.username;
      group = "users";
      mode = "0400";
      restartUnits = [ "paseo.service" ];
    };

    # Pi reads this in interactive shells and as a Paseo subprocess, so the
    # decrypted file is relaxed to the user.
    "deepseek-api-key" = {
      owner = config.nixos-core.base.username;
      group = "users";
      mode = "0400";
      restartUnits = [ "paseo.service" ];
    };
  };

  # Render the token into each consumer's expected shape. The value never
  # reaches the Nix store: sops-nix substitutes the placeholder at activation.
  #
  # Gated on the key existing. `sops.placeholder` is derived from
  # `sops.secrets`, so reading a placeholder for a secret that
  # `warnOnMissingKeys` filtered out is an evaluation error, not a warning.
  sops.templates = lib.mkMerge [
    (lib.mkIf hasDeepSeekKey {
      "paseo-deepseek.env" = {
        owner = config.nixos-core.base.username;
        group = "users";
        mode = "0400";
        content = ''
          DEEPSEEK_API_KEY=${config.sops.placeholder."deepseek-api-key"}
        '';
      };
    })
    (lib.mkIf hasAtticSigningKey {
      "atticd.env" = {
        owner = "root";
        group = "root";
        mode = "0400";
        content = ''
          ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=${config.sops.placeholder."attic-signing-key"}
        '';
      };
    })
  ];

  # Consume tailscale-auth-key for declarative tailnet re-auth. The provider owns
  # the secret *declaration*; nixos-core.base owns the *service* wiring — the
  # consumer only names the secret and reads its path (RUNBOOK §5).
  nixos-core.base.tailscale.authKeyFile = config.sops.secrets."tailscale-auth-key".path;
}
