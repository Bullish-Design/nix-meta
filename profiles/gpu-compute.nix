inputs:
{ config, lib, pkgs, ... }:

let
  inherit (inputs) nixos-core;
  cfg = config.nix-meta.gpu-compute;
  amdGpuDevices = lib.concatStringsSep " " (map lib.escapeShellArg cfg.amd.pciDevices);
  expectedAmdGpuDeviceId =
    if cfg.amd.model == "mi25" then "0x6860"
    else if cfg.amd.model == "v620" then "0x73a1"
    else "";
  mi25Cards = map (bdf: {
    inherit bdf;
    table = ../nix/mi25-card0-150.pp_table;
  }) cfg.amd.pciDevices;

  enableAmdgpuRuntimePm = pkgs.writeShellScript "enable-amdgpu-runtime-pm" ''
    set -eu

    for bdf in ${amdGpuDevices}; do
      pci="/sys/bus/pci/devices/$bdf"
      if [ ! -r "$pci/vendor" ] || [ "$(cat "$pci/vendor")" != 0x1002 ]; then
        echo "AMDGPU runtime-PM target is not an AMD PCI device: $pci" >&2
        exit 1
      fi
      if [ -n "${expectedAmdGpuDeviceId}" ] \
        && [ "$(cat "$pci/device")" != "${expectedAmdGpuDeviceId}" ]; then
        echo "AMD GPU model mismatch at $pci: expected ${expectedAmdGpuDeviceId}, got $(cat "$pci/device")" >&2
        exit 1
      fi
      if [ "$(readlink -f "$pci/driver" 2>/dev/null || true)" != /sys/bus/pci/drivers/amdgpu ]; then
        echo "AMDGPU runtime-PM target is not bound to amdgpu: $pci" >&2
        exit 1
      fi

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
    ../nix/mi25-power-table.nix
  ];

  options.nix-meta.gpu-compute = {
    amd.enable = lib.mkEnableOption "headless AMDGPU/ROCm support";

    amd.model = lib.mkOption {
      type = lib.types.enum [ "generic" "mi25" "v620" ];
      default = "generic";
      description = ''
        Optional model-specific policy. The MI25 profile enables its reviewed
        power table. The V620 profile checks PCI identity and leaves firmware
        power limits unchanged.
      '';
    };

    amd.pciDevices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "0000:01:00.0" "0000:02:00.0" ];
      description = ''
        Host-specific PCI addresses for the AMD GPUs. Keep this order aligned
        with the ROCm device order used by the GPU load harness.
      '';
    };

    nvidia.enable = lib.mkEnableOption "headless NVIDIA/CUDA support";
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.amd.enable || (cfg.amd.model == "generic");
          message = "Select an AMD GPU model only when nix-meta.gpu-compute.amd.enable is true.";
        }
        {
          assertion = (cfg.amd.model == "generic") || (cfg.amd.pciDevices != [ ]);
          message = "A model-specific AMD GPU profile requires nix-meta.gpu-compute.amd.pciDevices.";
        }
      ];
    }

    (lib.mkIf cfg.amd.enable {
      boot.kernelParams = [ "amdgpu.runpm=1" ];

      # RADV Vulkan ICD for the AMD compute backend. The nvidia-compute module
      # supplied this before the backends became independent flags. The AMD
      # path must request it directly, or /run/opengl-driver does not exist.
      hardware.graphics.enable = true;

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
    })

    (lib.mkIf (cfg.amd.enable && cfg.amd.pciDevices != [ ]) {
      environment.etc."nix-meta/gpu-compute/amd-pci-devices".text =
        (lib.concatStringsSep "\n" cfg.amd.pciDevices) + "\n";

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

    (lib.mkIf (cfg.amd.enable && cfg.amd.model == "mi25") {
      # MI25 OverDrive and its reviewed soft PowerPlay table stay opt-in.
      boot.kernelParams = [ "amdgpu.ppfeaturemask=0xffffffff" ];
      services.inferference-mi25-power-table = {
        enable = true;
        cards = mi25Cards;
      };
    })

    (lib.mkIf (cfg.amd.enable && cfg.amd.model == "v620") {
      # V620 power-cap floor. The VBIOS sets hwmon power1_cap min = max = 250 W,
      # so root cannot lower the PPT limit. A runtime pp_table upload does not
      # work: it wedges the SMU (inferference project 032, incident 2026-10-08).
      # This kernel patch lowers only the minimum to 120 W, and only for PCI
      # 1002:73a1 with subsystem 1002:0e34. The default and maximum stay at 250 W.
      # The cap changes only when root writes power1_cap (SetPptLimit message).
      # Re-check the patch on every kernel bump. A failed apply stops the build.
      boot.kernelPatches = [
        {
          name = "v620-powercap-min-120w";
          patch = ./patches/v620-powercap-min-120w.patch;
        }
      ];
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
