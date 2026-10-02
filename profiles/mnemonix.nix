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

    # Keep all extraction and reflection on the loopback Inferference router.
    # The model ID must be loaded there; the Mnemonix module supplies a local
    # placeholder key for Hindsight's OpenAI-compatible client.
    provider = "openai";
    model = "qwen38-27b";
    baseUrl = "http://127.0.0.1:8100/v1";
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
