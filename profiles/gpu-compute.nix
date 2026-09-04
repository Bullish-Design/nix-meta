inputs:
{ config, lib, pkgs, ... }:

let
  inherit (inputs) nixos-core;
  cfg = config.nix-meta.gpu-compute;

  enableAmdgpuRuntimePm = pkgs.writeShellScript "enable-amdgpu-runtime-pm" ''
    set -eu

    for pci in /sys/bus/pci/devices/0000:19:00.0 /sys/bus/pci/devices/0000:67:00.0; do
      control="$pci/power/control"
      if [ ! -w "$control" ]; then
        echo "AMDGPU runtime-PM control is unavailable: $control" >&2
        exit 1
      fi

      printf '%s\n' auto > "$control"
      if [ "$(${pkgs.coreutils}/bin/cat "$control")" != auto ]; then
        echo "AMDGPU runtime-PM control did not accept auto: $control" >&2
        exit 1
      fi
    done
  '';
in
{
  imports = [
    nixos-core.nixosModules.nvidia-compute
  ];

  options.nix-meta.gpu-compute = {
    amd.enable = lib.mkEnableOption "headless AMDGPU/ROCm support";
    nvidia.enable = lib.mkEnableOption "headless NVIDIA/CUDA support";
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.amd.enable {
      boot.kernelParams = [ "amdgpu.runpm=1" ];

      environment.systemPackages = with pkgs; [
        amdgpu_top
        clinfo
        rocmPackages.amdsmi
        rocmPackages.rocm-smi
        rocmPackages.rocminfo
        rocmPackages.rocm-bandwidth-test
        rocmPackages.rocblas.benchmark
        rocmPackages.rocgdb
        rocmPackages.rocprofiler
      ];

      systemd.services.amdgpu-headless-runtime-pm = {
        description = "Allow headless AMD GPUs to runtime-suspend when idle";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-modules-load.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = enableAmdgpuRuntimePm;
        };
      };
    })

    (lib.mkIf cfg.nvidia.enable {
      # Headless CUDA substrate for local LLM inference on a host with supported
      # NVIDIA GPUs. This remains disabled on the AMD-only server.
      nixos-core.nvidia-compute = {
        enable = true;

        # Sane initial cap: RTX 3060 stock TDP is ~170 W; the module notes
        # ~120-130 W ≈ 70%, which trims heat/draw with negligible inference hit.
        powerLimitWatts = 130;
      };
    })
  ];
}
