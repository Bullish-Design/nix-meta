inputs:
{ config, lib, ... }:

let
  username = config.nixos-core.base.username;

  # The runtime map scans this root. Exclusions stay in a small source file, so
  # creating a project or editing the list does not require a machine rebuild.
  projectsRoot = "/home/${username}/Documents/Projects";
  memignoreFile = "${projectsRoot}/mnemonix/.memignore";

  hindsight = config.services.mnemonix.hindsight;
in
{
  imports = [ inputs.mnemonix.nixosModules.mnemonix ];

  # ── Hindsight, the memory service ──────────────────────────────────────────
  #
  # Plain Hindsight and nothing layered on top: retain, recall, and its own
  # synthesized knowledge pages, shared by the three agents. No policy files,
  # no task router, no curated bank tiers.
  services.mnemonix.hindsight = {
    enable = true;
    inherit projectsRoot memignoreFile;

    # 8891, not upstream's 8888 — machines/server.nix already binds 8888 for
    # the Atuin sync server.
    apiPort = 8891;
    uiPort = 9991;

    # Retain and reflect go to vLLM on tower, a Windows desktop on the tailnet.
    # Mnemonix derives provider, model and baseUrl from this one word; see
    # mnemonix's tower/README.md for why the endpoint is HTTPS on 443 and not
    # port 8000. Inferference is untouched by this and stays the fallback.
    #
    # There is no automatic failover: Hindsight takes a single base URL. If
    # tower is down, switch this to "inferference" and rebuild.
    #
    # No environmentFile and no secret: tower serves a local model with no API
    # key, so Mnemonix supplies the non-secret placeholder its
    # OpenAI-compatible client needs. Access control is the loopback publish on
    # tower, a Serve mapping scoped to /v1 and /health, and the tailnet ACL.
    llmBackend = "tower-vllm";
  };

  # ── The shared agent configuration ─────────────────────────────────────────
  #
  # Home Manager owns the shared Hindsight settings, Pi extension and skill,
  # and Codex hooks. Claude's managed settings come from the NixOS module.
  home-manager.users.${username} = {
    imports = [ inputs.mnemonix.homeManagerModules.mnemonix ];

    programs.mnemonix = {
      enable = true;
      inherit projectsRoot memignoreFile;
      autoInject = "pages";

      # Read the derived URL rather than restating the port. One declaration
      # above decides both the published port and what the agents dial.
      inherit (hindsight)
        apiUrl
        gitIngest
        retainExtractionMode
        maxParallelRetains
        ;
    };
  };
}
