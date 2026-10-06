{ config, lib, pkgs, ... }:

let
  gpuPciDevices = config.nix-meta.gpu-compute.amd.pciDevices;
  gpuPciDevicesForShell = lib.concatMapStringsSep " " lib.escapeShellArg gpuPciDevices;

  # ARCTIC ports that carry the two GPU duct fans. Channel N drives pwmN and
  # reports fanN_input. Change this list only after the physical channel map is
  # verified with scripts/arctic-fan-controller-test. Every other channel stays
  # at PWM 255.
  gpuFanChannels = [ 2 3 ];
  gpuFanChannelsForShell = lib.concatMapStringsSep " " toString gpuFanChannels;

  # Keep the system kernel unchanged. The driver source is taken from the
  # nixpkgs testing source where it is currently available, but compiled and
  # installed as an out-of-tree module for this host's selected kernel.
  arcticFanController = pkgs.callPackage ../../pkgs/arctic-fan-controller {
    kernel = config.boot.kernelPackages.kernel;
    driverSource = pkgs.linuxPackages_testing.kernel.src;
  };

  # The driver registers this exact hwmon name. The hwmonN number is not stable
  # and is intentionally never used here.
  allFansHigh = pkgs.writeShellScriptBin "arctic-fans-100" ''
    set -u

    hwmon=""
    tries=0
    while [ -z "$hwmon" ] && [ "$tries" -lt 120 ]; do
      for h in /sys/class/hwmon/hwmon*; do
        if [ -r "$h/name" ] \
          && [ "$(${pkgs.coreutils}/bin/cat "$h/name")" = "arctic_fan" ]; then
          hwmon="$h"
          break
        fi
      done

      [ -n "$hwmon" ] && break
      tries=$((tries + 1))
      ${pkgs.coreutils}/bin/sleep 0.5
    done

    if [ -z "$hwmon" ]; then
      echo "ARCTIC Fan Controller hwmon device did not appear" >&2
      exit 1
    fi

    pwm_files=""
    count=0
    failed=0
    for pwm in "$hwmon"/pwm[0-9] "$hwmon"/pwm[0-9][0-9]; do
      [ -f "$pwm" ] || continue
      if ! printf '%s\n' 255 > "$pwm"; then
        echo "failed to write safe high value to $pwm" >&2
        failed=1
      fi
      pwm_files="$pwm_files $pwm"
      count=$((count + 1))
    done

    if [ "$count" -eq 0 ]; then
      echo "ARCTIC Fan Controller has no writable PWM channels" >&2
      exit 1
    fi

    for pwm in $pwm_files; do
      if ! value="$(${pkgs.coreutils}/bin/cat "$pwm")"; then
        echo "failed to read back $pwm" >&2
        failed=1
      elif [ "$value" != 255 ]; then
        echo "failed to verify $pwm: got $value" >&2
        failed=1
      fi
    done

    if [ "$failed" -ne 0 ]; then
      echo "ARCTIC Fan Controller safe-high verification failed" >&2
      exit 1
    fi

    echo "ARCTIC Fan Controller: verified $count PWM channel(s) at 100%"
  '';

  # This watchdog is the normal controller for the two GPU duct fans. It starts
  # high, uses the configured GPU PCI paths, and returns high on every error.
  # CoolerControl leaves the ARCTIC fans unmanaged; it remains the localhost UI
  # and hardware monitor.
  fanWatchdog = pkgs.writeShellScript "arctic-fan-watchdog" ''
    set -u

    safe_high() {
      if ! ${allFansHigh}/bin/arctic-fans-100; then
        echo "ARCTIC watchdog could not force safe high" >&2
        return 1
      fi
    }

    on_exit() {
      status=$?
      trap - EXIT HUP INT TERM
      safe_high || true
      exit "$status"
    }

    trap on_exit EXIT
    trap 'exit 143' HUP INT TERM

    if ! safe_high; then
      exit 1
    fi

    find_arctic_hwmon() {
      for h in /sys/class/hwmon/hwmon*; do
        if [ -r "$h/name" ] && [ "$(cat "$h/name")" = arctic_fan ]; then
          printf '%s\n' "$h"
          return 0
        fi
      done
      return 1
    }

    find_junction_sensor() {
      pci="$1"
      for h in "$pci"/hwmon/hwmon*; do
        [ -d "$h" ] || continue
        [ -r "$h/name" ] || continue
        [ "$(cat "$h/name")" = amdgpu ] || continue
        for label in "$h"/temp*_label; do
          [ -r "$label" ] || continue
          [ "$(cat "$label")" = junction ] || continue
          sensor="''${label%_label}_input"
          [ -r "$sensor" ] || continue
          printf '%s\n' "$sensor"
          return 0
        done
      done
      return 1
    }

    # Calibration is pending. Every GPU duct fan runs at full speed until the
    # calibration sweep measures a stable low value. Add a lower value only when
    # every GPU fan keeps a tach reading above min_running_rpm at that value.
    curve_pwm() {
      printf '%s\n' 255
    }

    # Thresholds for the fan failure latch. A GPU fan below min_running_rpm for
    # stall_samples consecutive samples is failed. Startup_grace_samples skips
    # the first samples while the fans start.
    min_running_rpm=500
    stall_samples=3
    startup_grace_samples=5

    declare -A pwm_now=() fan_rpm=() strikes=() failed=()
    gpu_channel_list="${gpuFanChannelsForShell}"
    gpu_channel_count=0
    for ch in ${gpuFanChannelsForShell}; do
      strikes[$ch]=0
      failed[$ch]=0
      gpu_channel_count=$((gpu_channel_count + 1))
    done

    # Write one value to every GPU duct channel, then read each channel back.
    write_gpu_pwm() {
      local arctic="$1" value="$2" ch readback
      for ch in ${gpuFanChannelsForShell}; do
        if ! printf '%s\n' "$value" > "$arctic/pwm$ch"; then
          echo "failed to write PWM $value to channel $ch; forcing safe high" >&2
          exit 1
        fi
        if ! readback="$(cat "$arctic/pwm$ch")" || [ "$readback" != "$value" ]; then
          echo "PWM readback failed on channel $ch: expected $value, got $readback" >&2
          exit 1
        fi
        pwm_now[$ch]="$readback"
      done
    }

    # The watchdog is readiness-gated so CoolerControl starts only after this
    # initial safe-high write has completed. This lets CoolerControl apply its
    # saved settings after the watchdog's startup barrier. During that brief
    # ordering window, wait for CoolerControl rather than treating it as a
    # runtime failure. Once it has been observed active, an inactive daemon is
    # a failure and the watchdog exits through the safe-high trap.
    ${pkgs.systemd}/bin/systemd-notify --ready
    startup_waits=0
    while ! ${pkgs.systemd}/bin/systemctl is-active --quiet coolercontrold.service; do
      if [ "$startup_waits" -ge 180 ]; then
        echo "CoolerControl did not start after watchdog readiness" >&2
        exit 1
      fi
      startup_waits=$((startup_waits + 1))
      ${pkgs.coreutils}/bin/sleep 0.5
    done

    samples=0
    cooldown_samples=0
    while :; do
      samples=$((samples + 1))
      if ! ${pkgs.systemd}/bin/systemctl is-active --quiet coolercontrold.service; then
        echo "CoolerControl is not active; forcing all ARCTIC channels high" >&2
        exit 1
      fi

      if ! arctic="$(find_arctic_hwmon)"; then
        echo "ARCTIC controller hwmon disappeared; forcing safe high" >&2
        exit 1
      fi

      # Read every PWM channel. GPU channels must hold a valid nonzero value.
      # Every other channel must stay at 255.
      pwm_count=0
      for pwm in "$arctic"/pwm[0-9] "$arctic"/pwm[0-9][0-9]; do
        [ -r "$pwm" ] || continue
        channel="''${pwm##*/pwm}"
        if ! value="$(cat "$pwm")"; then
          echo "failed to read $pwm; forcing safe high" >&2
          exit 1
        fi
        case "$value" in
          ""|*[!0-9]*)
            echo "invalid PWM value in $pwm: $value" >&2
            exit 1
            ;;
          0)
            echo "$pwm is zero; forcing safe high" >&2
            exit 1
            ;;
        esac
        if [ "$value" -gt 255 ]; then
          echo "invalid PWM value in $pwm: $value" >&2
          exit 1
        fi
        case " $gpu_channel_list " in
          *" $channel "*)
            pwm_now[$channel]="$value"
            ;;
          *)
            if [ "$value" -ne 255 ]; then
              echo "unused ARCTIC channel is not high: $pwm=$value" >&2
              exit 1
            fi
            ;;
        esac
        pwm_count=$((pwm_count + 1))
      done
      if [ "$pwm_count" -eq 0 ]; then
        echo "ARCTIC controller has no readable PWM channels" >&2
        exit 1
      fi

      for ch in ${gpuFanChannelsForShell}; do
        if [ ! -r "$arctic/pwm$ch" ] || [ ! -r "$arctic/fan''${ch}_input" ]; then
          echo "GPU duct channel $ch is missing its PWM or tach attribute; forcing safe high" >&2
          exit 1
        fi
      done

      # Read every GPU tach. A read error or invalid value forces safe high.
      # A low tach value counts toward the stall latch for that channel.
      for ch in ${gpuFanChannelsForShell}; do
        if ! rpm="$(cat "$arctic/fan''${ch}_input")"; then
          echo "tach read failed on GPU duct channel $ch; forcing safe high" >&2
          exit 1
        fi
        case "$rpm" in
          ""|*[!0-9]*)
            echo "invalid tach value on GPU duct channel $ch: $rpm" >&2
            exit 1
            ;;
        esac
        fan_rpm[$ch]="$rpm"
        if [ "$rpm" -lt "$min_running_rpm" ]; then
          strikes[$ch]=$((strikes[$ch] + 1))
        else
          strikes[$ch]=0
        fi
        if [ "$samples" -gt "$startup_grace_samples" ] \
          && [ "''${strikes[$ch]}" -ge "$stall_samples" ] \
          && [ "''${failed[$ch]}" -eq 0 ]; then
          failed[$ch]=1
          echo "CRITICAL: GPU duct channel $ch stopped at $rpm RPM; latched as failed" >&2
        fi
      done

      failed_count=0
      for ch in ${gpuFanChannelsForShell}; do
        if [ "''${failed[$ch]}" -ne 0 ]; then
          failed_count=$((failed_count + 1))
        fi
      done
      if [ "$failed_count" -eq 0 ]; then
        state=OK
      elif [ "$failed_count" -lt "$gpu_channel_count" ]; then
        state=DEGRADED
      else
        state=NO_AIRFLOW
      fi

      max_junction=""
      for bdf in ${gpuPciDevicesForShell}; do
        pci="/sys/bus/pci/devices/$bdf"
        if ! sensor="$(find_junction_sensor "$pci")"; then
          echo "GPU junction sensor missing at $pci; forcing safe high" >&2
          exit 1
        fi
        if ! value="$(cat "$sensor")"; then
          echo "GPU junction read failed at $sensor; forcing safe high" >&2
          exit 1
        fi
        case "$value" in
          ""|*[!0-9]*)
            echo "invalid GPU junction value at $sensor: $value" >&2
            exit 1
            ;;
        esac
        if [ -z "$max_junction" ] || [ "$value" -gt "$max_junction" ]; then
          max_junction="$value"
        fi
      done

      target_pwm="$(curve_pwm "$max_junction")"
      if [ "$failed_count" -gt 0 ]; then
        # PWM cannot repair a stopped motor. Hold every channel high while any
        # GPU fan is failed. The remaining fans give the most airflow available.
        target_pwm=255
      fi

      needs_up=0
      needs_down=0
      for ch in ${gpuFanChannelsForShell}; do
        if [ "$target_pwm" -gt "''${pwm_now[$ch]}" ]; then
          needs_up=1
        fi
        if [ "$target_pwm" -lt "''${pwm_now[$ch]}" ]; then
          needs_down=1
        fi
      done

      if [ "$needs_up" -eq 1 ]; then
        # Ramp up without delay when the maximum junction temperature rises.
        cooldown_samples=0
        write_gpu_pwm "$arctic" "$target_pwm"
      elif [ "$needs_down" -eq 1 ]; then
        # Require five consecutive cool samples before ramping down.
        cooldown_samples=$((cooldown_samples + 1))
        if [ "$cooldown_samples" -ge 5 ]; then
          write_gpu_pwm "$arctic" "$target_pwm"
          cooldown_samples=0
        fi
      else
        cooldown_samples=0
      fi

      detail=""
      for ch in ${gpuFanChannelsForShell}; do
        detail="$detail channel$ch(pwm=''${pwm_now[$ch]} rpm=''${fan_rpm[$ch]} failed=''${failed[$ch]})"
      done

      printf 'state=%s target_pwm=%s max_gpu_junction_mC=%s\n' "$state" "$target_pwm" "$max_junction" \
        > /run/arctic-fan/status || echo "could not write /run/arctic-fan/status" >&2
      ${pkgs.systemd}/bin/systemd-notify --status="$state target_pwm=$target_pwm" || true
      echo "ARCTIC watchdog: state=$state max_gpu_junction_mC=$max_junction target_pwm=$target_pwm cooldown_samples=$cooldown_samples$detail"
      ${pkgs.coreutils}/bin/sleep 2
    done
  '';

  # A `nixos-rebuild switch` keeps the booted generation in /run/booted-system.
  # systemd-modules-load therefore cannot see a module added by the new
  # generation until reboot. Load this exact, kernel-matched module path during
  # activation and skip the insert when boot already loaded the module.
  loadArcticModule = pkgs.writeShellScript "load-arctic-fan-controller" ''
    set -eu

    expected_kernel="${config.boot.kernelPackages.kernel.modDirVersion}"
    running_kernel="$(${pkgs.coreutils}/bin/uname -r)"
    if [ "$running_kernel" != "$expected_kernel" ]; then
      echo "ARCTIC module requires kernel $expected_kernel, running $running_kernel" >&2
      exit 1
    fi

    if ${pkgs.gnugrep}/bin/grep -q '^arctic_fan_controller ' /proc/modules; then
      exit 0
    fi

    ${pkgs.kmod}/bin/insmod \
      "${arcticFanController}/lib/modules/${config.boot.kernelPackages.kernel.modDirVersion}/updates/arctic_fan_controller.ko"

    if ! ${pkgs.gnugrep}/bin/grep -q '^arctic_fan_controller ' /proc/modules; then
      echo "ARCTIC module insert completed without appearing in /proc/modules" >&2
      exit 1
    fi
  '';
in
{
  assertions = [
    {
      assertion = config.nix-meta.gpu-compute.amd.enable && (builtins.length gpuPciDevices == 2);
      message = "The ARCTIC GPU fan watchdog requires exactly two configured AMD GPU PCI addresses.";
    }
    {
      assertion = builtins.length gpuFanChannels == 2;
      message = "The ARCTIC GPU fan watchdog requires exactly two GPU duct fan channels.";
    }
  ];

  boot.extraModulePackages = [ arcticFanController ];
  boot.kernelModules = [ "arctic_fan_controller" ];

  environment.systemPackages = [ allFansHigh ];

  # Test scripts read the same channel list as the watchdog.
  environment.etc."nix-meta/arctic-fan/gpu-duct-channels".text =
    lib.concatMapStrings (channel: "${toString channel}\n") gpuFanChannels;

  systemd.services.arctic-fan-module-load = {
    description = "Load the kernel-matched ARCTIC Fan Controller module";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    before = [ "arctic-fan-safe-high.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = loadArcticModule;
    };
  };

  # This service is deliberately persistent. CoolerControl requires it, so a
  # failed safety initialization prevents CoolerControl from taking control.
  systemd.services.arctic-fan-safe-high = {
    description = "Set all ARCTIC Fan Controller channels to safe high";
    wantedBy = [ "multi-user.target" ];
    requires = [ "arctic-fan-module-load.service" ];
    after = [ "systemd-modules-load.service" "arctic-fan-module-load.service" ];
    before = [ "coolercontrold.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${allFansHigh}/bin/arctic-fans-100";
      TimeoutStartSec = "90s";
    };
  };

  # If CoolerControl stops or crashes, restore all channels to 100%. This is
  # independent of CoolerControl's saved profiles and control loop.
  systemd.services.coolercontrold = {
    requires = [ "arctic-fan-safe-high.service" "arctic-fan-watchdog.service" ];
    after = [ "arctic-fan-safe-high.service" "arctic-fan-watchdog.service" ];
    serviceConfig.ExecStopPost = "${allFansHigh}/bin/arctic-fans-100";
  };

  systemd.services.arctic-fan-watchdog = {
    description = "Independent fail-high watchdog for ARCTIC GPU duct cooling";
    wantedBy = [ "multi-user.target" ];
    requires = [ "arctic-fan-safe-high.service" ];
    after = [ "arctic-fan-safe-high.service" ];
    before = [ "coolercontrold.service" "shutdown.target" ];

    # systemd reads the start limit from [Unit], not [Service].
    unitConfig = {
      StartLimitIntervalSec = "60s";
      StartLimitBurst = 6;
    };

    serviceConfig = {
      Type = "notify";
      NotifyAccess = "main";
      # Writes /run/arctic-fan/status. Lists the state for each GPU fan.
      RuntimeDirectory = "arctic-fan";
      ExecStart = fanWatchdog;
      ExecStopPost = "${allFansHigh}/bin/arctic-fans-100";
      Restart = "on-failure";
      RestartSec = "10s";
      TimeoutStopSec = "90s";
    };
  };
}
