inputs:
{ ... }:

let
  inherit (inputs) nixos-core;
in
{
  imports = [
    nixos-core.nixosModules.nvidia-compute
  ];

  # Headless CUDA substrate for local LLM inference on the 2x RTX 3060 12GB
  # (Ampere GA106, CUDA cap 8.6). This is the driver + container-toolkit layer
  # only — no display stack. The module pulls hardware.graphics + the open
  # kernel module and turns on the cuda-maintainers cachix substituter (CUDA is
  # built from source otherwise).
  nixos-core.nvidia-compute = {
    enable = true;

    # Sane initial cap: RTX 3060 stock TDP is ~170 W; the module notes
    # ~120-130 W ≈ 70%, which trims heat/draw with negligible inference hit.
    # Start conservative — the OPTIMAL value is empirical, tune on-box.
    powerLimitWatts = 130;

    # Everything else stays at the module defaults, all of which are empirical
    # and flagged to tune on-box (nixos-core-PLAN §10-Q8):
    #   cudaCapabilities   = [ "8.6" ]        (Ampere GA106 — correct for 3060)
    #   containerToolkit   = enabled          (GPU-in-Docker for vLLM/act)
    #   persistenceMode    = on               (nvidia-smi -pm 1)
    #   minimizeFbconVram  = on → fbcon=nodefer kernel param (verify on-box)
    #   cachix             = cuda-maintainers substituter + key
  };
}
