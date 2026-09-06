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
      # ppfeaturemask: unmask OverDrive (bit 0x00004000, PP_OVERDRIVE_MASK).
      #
      # Without it amdgpu never creates pp_od_clk_voltage and pins
      # power1_cap_max to power1_cap_default, so the MI25s' 110 W cap cannot be
      # raised at all — measured 0xfff7bfff against the amdgpu default of
      # 0xfff7ffff. The 110 W is the flashed firmware's default, not a PSU,
      # riser or slot-power limit, so the ceiling is a tuning question.
      #
      # Expect a MODEST return. Inferference project 011 swept the cap downward
      # and measured the efficiency curve flattening to 0.065 tok/s per watt at
      # the top of the range, so ~150 W extrapolates to roughly +16% decode, not
      # the 2x an earlier report implied. It is still the largest lever left:
      # every governor knob tested came in at +-4% synthetic and -13% on real
      # serving traffic.
      #
      # It may also do nothing. Unmasking tells the driver to OFFER headroom;
      # how much is bounded by the flashed power table. After a reboot, check:
      #   cat /sys/module/amdgpu/parameters/ppfeaturemask      # expect 0xffffffff
      #   ls  /sys/class/drm/card0/device/pp_od_clk_voltage    # expect it to exist
      #   cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap_max
      # If power1_cap_max is still 110 W, the driver is willing and the firmware
      # is not. Reverting is removing this one string and rebuilding.
      boot.kernelParams = [ "amdgpu.runpm=1" "amdgpu.ppfeaturemask=0xffffffff" ];

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
