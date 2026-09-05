{ config, pkgs, ... }:

let
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

  # This watchdog is the normal controller for the mapped GPU duct fan. It
  # starts high, uses both stable GPU PCI paths, and returns high on every
  # error. CoolerControl leaves the ARCTIC fan unmanaged; it remains the
  # localhost UI and hardware monitor.
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

    curve_pwm() {
      junction="$1"
      # The measured minimum reliable value is 180. Use full speed before
      # 70 C, with a conservative margin below the requested 75--80 C limit.
      if [ "$junction" -ge 65000 ]; then
        printf '%s\n' 255
      elif [ "$junction" -ge 60000 ]; then
        printf '%s\n' 245
      elif [ "$junction" -ge 55000 ]; then
        printf '%s\n' 230
      elif [ "$junction" -ge 50000 ]; then
        printf '%s\n' 215
      elif [ "$junction" -ge 45000 ]; then
        printf '%s\n' 200
      else
        printf '%s\n' 180
      fi
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

    cooldown_samples=0
    while :; do
      if ! ${pkgs.systemd}/bin/systemctl is-active --quiet coolercontrold.service; then
        echo "CoolerControl is not active; forcing all ARCTIC channels high" >&2
        exit 1
      fi

      if ! arctic="$(find_arctic_hwmon)"; then
        echo "ARCTIC controller hwmon disappeared; forcing safe high" >&2
        exit 1
      fi

      pwm_count=0
      pwm1_value=""
      for pwm in "$arctic"/pwm[0-9] "$arctic"/pwm[0-9][0-9]; do
        [ -r "$pwm" ] || continue
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
        case "$pwm" in
          "$arctic"/pwm1)
            pwm1_value="$value"
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
      if [ -z "$pwm1_value" ]; then
        echo "mapped GPU duct channel pwm1 is missing; forcing safe high" >&2
        exit 1
      fi

      max_junction=""
      for pci in /sys/bus/pci/devices/0000:19:00.0 /sys/bus/pci/devices/0000:67:00.0; do
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
      if [ "$target_pwm" -gt "$pwm1_value" ]; then
        # Ramp up without delay when the maximum junction temperature rises.
        cooldown_samples=0
        if ! printf '%s\n' "$target_pwm" > "$arctic/pwm1"; then
          echo "failed to increase GPU duct PWM to $target_pwm; forcing safe high" >&2
          exit 1
        fi
        if ! readback="$(cat "$arctic/pwm1")" || [ "$readback" != "$target_pwm" ]; then
          echo "GPU duct PWM ramp-up readback failed: expected $target_pwm, got $readback" >&2
          exit 1
        fi
        pwm1_value="$readback"
      elif [ "$target_pwm" -lt "$pwm1_value" ]; then
        # Require five consecutive cool samples before ramping down.
        cooldown_samples=$((cooldown_samples + 1))
        if [ "$cooldown_samples" -ge 5 ]; then
          if ! printf '%s\n' "$target_pwm" > "$arctic/pwm1"; then
            echo "failed to decrease GPU duct PWM to $target_pwm; forcing safe high" >&2
            exit 1
          fi
          if ! readback="$(cat "$arctic/pwm1")" || [ "$readback" != "$target_pwm" ]; then
            echo "GPU duct PWM ramp-down readback failed: expected $target_pwm, got $readback" >&2
            exit 1
          fi
          pwm1_value="$readback"
          cooldown_samples=0
        fi
      else
        cooldown_samples=0
      fi

      echo "ARCTIC watchdog: max_gpu_junction_mC=$max_junction target_pwm1=$target_pwm actual_pwm1=$pwm1_value cooldown_samples=$cooldown_samples"
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
  boot.extraModulePackages = [ arcticFanController ];
  boot.kernelModules = [ "arctic_fan_controller" ];

  environment.systemPackages = [ allFansHigh ];

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

    serviceConfig = {
      Type = "notify";
      NotifyAccess = "main";
      ExecStart = fanWatchdog;
      ExecStopPost = "${allFansHigh}/bin/arctic-fans-100";
      Restart = "on-failure";
      RestartSec = "10s";
      StartLimitIntervalSec = "60s";
      StartLimitBurst = 6;
      TimeoutStopSec = "90s";
    };
  };
}
