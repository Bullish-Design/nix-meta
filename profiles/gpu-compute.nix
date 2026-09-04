inputs:
{ config, lib, ... }:

let
  inherit (inputs) nixos-core;
  cfg = config.nix-meta.gpu-compute;
in
{
  imports = [
    nixos-core.nixosModules.nvidia-compute
  ];

  options.nix-meta.gpu-compute = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the optional headless NVIDIA/CUDA compute layer.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Headless CUDA substrate for local LLM inference on a host with supported
    # NVIDIA GPUs. This remains disabled on the AMD-only server.
    nixos-core.nvidia-compute = {
      enable = true;

      # Sane initial cap: RTX 3060 stock TDP is ~170 W; the module notes
      # ~120-130 W ≈ 70%, which trims heat/draw with negligible inference hit.
      powerLimitWatts = 130;
    };
  };
}
