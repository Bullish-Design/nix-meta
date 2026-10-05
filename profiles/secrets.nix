inputs:
{ config, lib, ... }:

let
  inherit (inputs) nix-secrets;

  # True once deepseek-api-key has material in the encrypted store. Everything
  # that reads its placeholder is gated on this, so a rebuild succeeds while the
  # secret is still unprovisioned.
  hasDeepSeekKey = config.sops.secrets ? "deepseek-api-key";

  # Same gate for the key Hindsight presents to tower's vLLM server.
  hasVllmKey = config.sops.secrets ? "mnemonix-vllm-api-key";
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
    # Consumed by Pi and Paseo. Mnemonix Hindsight deliberately does not receive
    # this credential: its retain and reflect calls go to a local model, either
    # the loopback Inferference router or vLLM on tower, never to DeepSeek.
    # `warnOnMissingKeys` is true, so until the material lands in nix-secrets
    # this name is dropped with an eval warning instead of failing the rebuild.
    "deepseek-api-key"
    # Hindsight's bearer token for the vLLM backend on tower. The same value
    # is pushed to tower as VLLM_API_KEY by mnemonix's deploy script, so one
    # secret configures both ends. Defence in depth behind the tailnet ACL:
    # vLLM authenticates only /v1, /v2 and /inference.
    "mnemonix-vllm-api-key"
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

    # mnemonix-vllm-api-key needs no entry here. Nothing reads the raw secret —
    # only the rendered mnemonix-hindsight.env below — and sops-nix already
    # defaults to root:root 0400, which is what that template wants.
  };

  # Render the token into each consumer's expected shape. The value never
  # reaches the Nix store: sops-nix substitutes the placeholder at activation.
  #
  # Gated on the key existing. `sops.placeholder` is derived from
  # `sops.secrets`, so reading a placeholder for a secret that
  # `warnOnMissingKeys` filtered out is an evaluation error, not a warning.
  # mkMerge, not `//`: `mkIf` returns a wrapper attrset, so `//`-ing a second
  # template onto it would merge into that wrapper and silently drop the
  # template instead of defining it.
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

    # Hindsight's environmentFile for the tower vLLM backend. Root-only: only
    # the Hindsight container reads it. Restart the container on rotation,
    # otherwise it keeps presenting the previous key.
    (lib.mkIf hasVllmKey {
      "mnemonix-hindsight.env" = {
        mode = "0400";
        restartUnits = [ "docker-mnemonix-hindsight.service" ];
        content = ''
          HINDSIGHT_API_LLM_API_KEY=${config.sops.placeholder."mnemonix-vllm-api-key"}
        '';
      };
    })
  ];

  # Consume tailscale-auth-key for declarative tailnet re-auth. The provider owns
  # the secret *declaration*; nixos-core.base owns the *service* wiring — the
  # consumer only names the secret and reads its path (RUNBOOK §5).
  nixos-core.base.tailscale.authKeyFile = config.sops.secrets."tailscale-auth-key".path;
}
