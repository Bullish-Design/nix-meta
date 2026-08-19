inputs:
{ config, lib, pkgs, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
  piPkgs = import inputs.pi-nixpkgs { inherit system; };
  atuinPackage = inputs.atuin.packages.${system}.atuin;
  username = config.nixos-core.base.username;
in

{
  imports = [ inputs.home-manager.nixosModules.home-manager ];

  # Agent tooling for working ON the box over SSH. This profile is the SOLE
  # installation point for agent CLIs: Claude Code + Codex (from sadjow's pinned
  # flakes — the same upstream devman used to bundle; see terminal.nix which
  # keeps the devman orchestrator but drops the bundled agents) + Pi (pinned via
  # pi-nixpkgs below). Per-repo toolchains still come from each repo's devenv.
  # Stacked on top of `minimal` like gpu-compute, so it's trivial to promote
  # into nixos-core.base (fleet-wide) or drop later.
  environment.systemPackages = with pkgs; [
    inputs.claude-code.packages.${system}.default
    inputs.codex-cli.packages.${system}.default
    # zellij: terminal multiplexer so long agent runs survive an SSH drop
    # (network switch / laptop sleep) — reattach with `zellij attach`. Also the
    # fleet-standard multiplexer, a precursor to the zelligate workspace daemon.
    zellij
  ];

  # The binaries live read-only in the Nix store, so their self-updaters can
  # never succeed — silence them. Updates happen by bumping the pinned inputs
  # (`nix flake update claude-code codex-cli`) + rebuild.
  environment.variables.DISABLE_AUTOUPDATER = "1";

  # Pi is a normal, locally installed CLI that Paseo discovers and launches as
  # a subprocess. Its package comes from pi-nixpkgs rather than the host's main
  # nixpkgs pin, letting Pi be upgraded and rolled back independently.
  home-manager.users.${username} = {
    # Codex sends PostToolUse.tool_response as a string, while Atuin 18.18.1
    # expects an object. Codex sessions launched outside an Atuin-initialized
    # shell also lack ATUIN_SESSION. Normalize both inputs until the upstream
    # hook protocols converge.
    home.file.".local/bin/atuin-codex-hook" = {
      executable = true;
      text = ''
        #!${pkgs.runtimeShell}

        set -euo pipefail

        payload="$(${pkgs.coreutils}/bin/cat)"

        if [[ -z "''${ATUIN_SESSION:-}" ]]; then
          ATUIN_SESSION="$(${lib.getExe pkgs.jq} -r '.session_id // .turn_id // "codex"' <<<"$payload")"
          export ATUIN_SESSION
        fi

        ${lib.getExe pkgs.jq} -c '
          if (.tool_response | type) == "string" then
            .tool_response = {}
          else
            .
          end
        ' <<<"$payload" | ${lib.getExe' atuinPackage "atuin"} hook codex
      '';
    };

    # Direct SSH shells need the same runtime credential as the Paseo service.
    # The file is created by sops-nix at activation and is never copied to the
    # Nix store or Home Manager's generated configuration.
    programs.zsh.initContent = lib.mkAfter ''
      if [[ -r /run/secrets/deepseek-api-key ]]; then
        export DEEPSEEK_API_KEY="$(< /run/secrets/deepseek-api-key)"
      fi
    '';

    programs.pi-coding-agent = {
      enable = true;
      package = piPkgs.pi-coding-agent;

      # The literal environment reference is intentionally stored instead of a
      # token. Both direct shells and the Paseo systemd service must provide
      # DEEPSEEK_API_KEY at runtime; never put that secret in the Nix store.
      models = {
        providers.deepseek = {
          baseUrl = "https://api.deepseek.com";
          api = "openai-completions";
          apiKey = "$DEEPSEEK_API_KEY";
          models = [
            {
              id = "deepseek-v4-pro";
              name = "DeepSeek V4 Pro";
              contextWindow = 1000000;
              maxTokens = 384000;
              input = [ "text" ];
              reasoning = true;
              compat = {
                requiresReasoningContentOnAssistantMessages = true;
                thinkingFormat = "deepseek";
              };
            }
            {
              id = "deepseek-v4-flash";
              name = "DeepSeek V4 Flash";
              contextWindow = 1000000;
              maxTokens = 384000;
              input = [ "text" ];
              reasoning = true;
              compat = {
                requiresReasoningContentOnAssistantMessages = true;
                thinkingFormat = "deepseek";
              };
            }
          ];
        };
      };

      settings = {
        defaultProvider = "deepseek";
        defaultModel = "deepseek-v4-pro";
        defaultThinkingLevel = "high";
      };
    };
  };
}
