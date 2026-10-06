{ config, lib, pkgs, ... }:

let
  gpuPciDevices = config.nix-meta.gpu-compute.amd.pciDevices;
  gpuPciDevicesForShell = lib.concatMapStringsSep " " lib.escapeShellArg gpuPciDevices;

  # Selected AMD power profile, applied to every configured GPU.
  #
  # Profile 2, POWER_SAVING, is the only reversible control measured to lower
  # heat without a large speed cost. Project 02 measured, on a single-stream
  # decode against `auto` profile 0: mean power 187.5 W against 215.8 W over
  # telemetry seconds 30-45, junction 60 C against 66 C at second 45, peak
  # junction 67 C against a 72 C stop, and a 3.0% cost to both prompt and
  # decode rate.
  #
  # The driver requires `manual` before a profile write. Project 02 also
  # measured `manual` with profile 0 and found it equal to `auto` within 1%,
  # so `manual` itself is not a confound: manual+2 against auto+0 isolates the
  # profile.
  #
  # Known limit: under profile 2 a 27,601-token prefill still reached 72 C in
  # about 15 seconds. This setting is not expected to fix prefill on its own.
  powerProfile = 2;
  powerProfileName = "POWER_SAVING";
  performanceLevel = "manual";

  # Identity gates. The applier refuses a card that is not the expected V620,
  # because a profile index means something different on another ASIC.
  expectedVendor = "0x1002";
  expectedDevice = "0x73a1";
  expectedSubsystemVendor = "0x1002";
  expectedSubsystemDevice = "0x0e34";

  # Stock V620 PowerPlay table hash, read on 2026-10-05 and identical on both
  # cards. A different table means different profile semantics, so stop.
  expectedPpTableSha256 = "a6fc019fdada096422629293bee778e8857af3330fd2dc2de42dd9d9d921b1c8";

  applyProfile = pkgs.writeShellScript "amdgpu-apply-power-profile" ''
    set -uo pipefail

    sysfs_read() {
      ${pkgs.coreutils}/bin/cat "$1" 2>/dev/null
    }

    failures=0

    for bdf in ${gpuPciDevicesForShell}; do
      dev="/sys/bus/pci/devices/$bdf"

      if [ ! -d "$dev" ]; then
        echo "amdgpu-power-profile: $bdf is not present" >&2
        failures=$((failures + 1))
        continue
      fi

      vendor="$(sysfs_read "$dev/vendor")"
      device="$(sysfs_read "$dev/device")"
      subvendor="$(sysfs_read "$dev/subsystem_vendor")"
      subdevice="$(sysfs_read "$dev/subsystem_device")"
      if [ "$vendor" != "${expectedVendor}" ] || [ "$device" != "${expectedDevice}" ] \
        || [ "$subvendor" != "${expectedSubsystemVendor}" ] || [ "$subdevice" != "${expectedSubsystemDevice}" ]; then
        echo "amdgpu-power-profile: $bdf identity mismatch: $vendor:$device $subvendor:$subdevice" >&2
        failures=$((failures + 1))
        continue
      fi

      # A profile index is only meaningful against the table it was measured
      # on. Refuse a card whose PowerPlay table is not the stock blob.
      if [ ! -r "$dev/pp_table" ]; then
        echo "amdgpu-power-profile: $bdf has no readable pp_table" >&2
        failures=$((failures + 1))
        continue
      fi
      table_hash="$(${pkgs.coreutils}/bin/sha256sum "$dev/pp_table" | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
      if [ "$table_hash" != "${expectedPpTableSha256}" ]; then
        echo "amdgpu-power-profile: $bdf PowerPlay table hash is $table_hash, expected ${expectedPpTableSha256}" >&2
        failures=$((failures + 1))
        continue
      fi

      level_file="$dev/power_dpm_force_performance_level"
      profile_file="$dev/pp_power_profile_mode"
      if [ ! -w "$level_file" ] || [ ! -w "$profile_file" ]; then
        echo "amdgpu-power-profile: $bdf power controls are not writable" >&2
        failures=$((failures + 1))
        continue
      fi

      # The driver requires manual before it accepts a profile write.
      if ! ${pkgs.coreutils}/bin/printf '%s\n' "${performanceLevel}" > "$level_file"; then
        echo "amdgpu-power-profile: $bdf could not set ${performanceLevel}" >&2
        failures=$((failures + 1))
        continue
      fi
      if ! ${pkgs.coreutils}/bin/printf '%s\n' "${toString powerProfile}" > "$profile_file"; then
        echo "amdgpu-power-profile: $bdf could not select profile ${toString powerProfile}" >&2
        failures=$((failures + 1))
        continue
      fi

      # Read both controls back. A write that sysfs accepted is not proof the
      # driver applied it.
      level_now="$(sysfs_read "$level_file")"
      active_now="$(sysfs_read "$profile_file" | ${pkgs.gnugrep}/bin/grep '\*' | ${pkgs.coreutils}/bin/head -1)"
      if [ "$level_now" != "${performanceLevel}" ]; then
        echo "amdgpu-power-profile: $bdf level readback is '$level_now', expected ${performanceLevel}" >&2
        failures=$((failures + 1))
        continue
      fi
      # The driver right-aligns profile names in a fixed-width column, so the
      # active line reads ' 2   POWER_SAVING*:' with variable spacing and the
      # asterisk glued to the name. Compare the parsed index and name, never
      # the raw spacing: matching a literal 'N NAME' fails on every profile
      # whose name is shorter than the column.
      active_index="$(${pkgs.coreutils}/bin/printf '%s\n' "$active_now" | ${pkgs.gawk}/bin/awk '{print $1}')"
      active_name="$(${pkgs.coreutils}/bin/printf '%s\n' "$active_now" | ${pkgs.gawk}/bin/awk '{print $2}' | ${pkgs.coreutils}/bin/tr -d '*:')"
      if [ "$active_index" != "${toString powerProfile}" ] || [ "$active_name" != "${powerProfileName}" ]; then
        echo "amdgpu-power-profile: $bdf active profile readback is index='$active_index' name='$active_name'," \
          "expected ${toString powerProfile} ${powerProfileName} (raw: '$active_now')" >&2
        failures=$((failures + 1))
        continue
      fi

      # A failed readback above leaves the written value in place rather than
      # reverting. Profile 2 draws LESS power than the default, so an
      # unverified application is not a hazard, and reverting would flap
      # against the five-minute re-assert timer. The unit still fails loudly.
      echo "amdgpu-power-profile: $bdf level=$level_now profile=${toString powerProfile} ${powerProfileName} verified"
    done

    if [ "$failures" -ne 0 ]; then
      echo "amdgpu-power-profile: $failures card(s) failed; refusing to report success" >&2
      exit 1
    fi
  '';
in
{
  # The profile is a measured experiment setting, applied at the system level so
  # that every benchmark sees the same controls and the profile is the only
  # variable between comparison runs. Nothing else here changes clocks, the
  # 250 W power cap, the voltage offset, or the PowerPlay table.
  assertions = [
    {
      assertion = config.nix-meta.gpu-compute.amd.enable && gpuPciDevices != [ ];
      message = "The AMD GPU power profile unit requires configured GPU PCI addresses.";
    }
  ];

  environment.etc."nix-meta/gpu-compute/amd-power-profile".text = ''
    performance_level=${performanceLevel}
    power_profile_mode=${toString powerProfile}
    power_profile_name=${powerProfileName}
  '';

  systemd.services.amdgpu-power-profile = {
    description = "Select the measured AMD GPU power profile (${toString powerProfile} ${powerProfileName})";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = applyProfile;
    };
  };

  # The driver can reset these controls, for example across suspend or a GPU
  # reset, and a silent return to profile 0 would void every comparison made
  # against this setting. Re-assert and verify periodically. The applier is
  # idempotent, so a re-assert on an already-correct card is a no-op that still
  # logs a verified line.
  systemd.timers.amdgpu-power-profile-verify = {
    description = "Verify the AMD GPU power profile has not been reset";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
      AccuracySec = "30s";
    };
  };

  systemd.services.amdgpu-power-profile-verify = {
    description = "Re-assert and verify the AMD GPU power profile";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = applyProfile;
    };
  };
}
