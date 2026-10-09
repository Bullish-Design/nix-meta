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

  # Default board power cap, in watts, applied to every configured GPU.
  #
  # The owner chose 160 W on 2026-10-09, after inferference project 032
  # phase 4a swept 250 W down to 120 W on card 0 (fans at flat maximum,
  # `experiments/032-v620-board-power-cap/`). 160 W is the lowest cap that
  # leaves single-stream decode unchanged, about 20 tok/s, because decode is
  # memory bound. It is also the highest cap at which every run finished its
  # 300 second soak under the 75 C arm bound: peak junction 66 C, peak memory
  # 73 C. Against stock, prefill drops from 355 to 294 tok/s (-17%). Against
  # 200 W, 8-lane aggregate speed drops from 66 to 60 tok/s (-10%).
  #
  # 180 W kept 7% more prefill, but its memory sensor reached 75 C after 4 to
  # 5 minutes of continuous load. Below 160 W the losses grow quickly: at
  # 140 W decode is -6% and prefill -12%; at 120 W decode is -29%.
  #
  # The stock kernel sets power1_cap_min above this target. The patched kernel
  # (profiles/patches/v620-powercap-min-120w.patch) lowers power1_cap_min to
  # 120 W. A power1_cap write does not survive a reboot or a GPU reset. A reset
  # restores 250 W. The five-minute timer re-asserts the cap.
  powerCapWatts = 160;

  # An experiment creates this file to hold a different cap. While it exists,
  # the applier leaves power1_cap alone. The first line names the owner.
  powerCapHoldFile = "/run/nix-meta/amdgpu-power-cap-hold";
  powerProfileName = "POWER_SAVING";
  performanceLevel = "manual";

  # Identity gates. The applier refuses a card that is not the expected V620,
  # because a profile index means something different on another ASIC.
  expectedVendor = "0x1002";
  expectedDevice = "0x73a1";
  expectedSubsystemVendor = "0x1002";
  expectedSubsystemDevice = "0x0e34";

  # Exact stock and reviewed project 032 table hashes. Unknown tables can
  # change profile semantics, so the applier must refuse them.
  acceptedPpTableSha256 = [
    "a6fc019fdada096422629293bee778e8857af3330fd2dc2de42dd9d9d921b1c8" # stock
    "eb2cff9c67b0fe01c6d4b6041d6ab6c19ee638ec454c7a25feaa589beb48b3d8" # thermal arm B
    "e2040fbc34210eef02a4c74a00d8d3e22700b87a5aa7320fc42fcd260e3ff35b" # thermal arm C
    "6d43d46574c09d42c4a2cf5a8ab1db015f9a0500487bf26dcec9671def281730" # thermal arm D
    "f1808c664058b66a919ef4b6395dad836c18ba17621bf85356c5f0182d7afc62" # cap 220 W
    "ed0e6402728f43ba47e160b4d19c896e6ffed0dc9014631766b9d2e443a8ac14" # cap 200 W
    "34b46aeb295fd59b4483f3789f1bbf3f9875d2984400bafcfbdf421a835f6a6c" # cap 180 W
  ];

  applyProfile = pkgs.writeShellScript "amdgpu-apply-power-profile" ''
    set -uo pipefail

    sysfs_read() {
      ${pkgs.coreutils}/bin/cat "$1" 2>/dev/null
    }

    failures=0

    # Apply the default power cap to one card. Run it after the profile is
    # verified. It counts one failure per card in "failures" and never reverts.
    apply_power_cap() {
      local bdf="$1" dev="$2" hwmon_dir="" candidate name_now
      local cap_file cap_min cap_max cap_now target_uw

      for candidate in "$dev"/hwmon/hwmon*; do
        [ -d "$candidate" ] || continue
        if [ -r "$candidate/name" ]; then
          name_now="$(sysfs_read "$candidate/name")"
          [ "$name_now" = "amdgpu" ] || continue
        fi
        hwmon_dir="$candidate"
        break
      done
      if [ -z "$hwmon_dir" ]; then
        echo "amdgpu-power-profile: $bdf has no amdgpu hwmon directory" >&2
        failures=$((failures + 1))
        return
      fi

      cap_file="$hwmon_dir/power1_cap"
      cap_now="$(sysfs_read "$cap_file")"

      # An experiment holds the cap with this file. Skip the write.
      if [ -e "${powerCapHoldFile}" ]; then
        hold_owner="$(${pkgs.coreutils}/bin/head -n 1 "${powerCapHoldFile}" 2>/dev/null)"
        echo "amdgpu-power-profile: $bdf cap held by $hold_owner; power1_cap=$(( ''${cap_now:-0} / 1000000 )) W"
        return
      fi

      target_uw=$(( ${toString powerCapWatts} * 1000000 ))
      cap_min="$(sysfs_read "$hwmon_dir/power1_cap_min")"
      cap_max="$(sysfs_read "$hwmon_dir/power1_cap_max")"
      case "$cap_min$cap_max$cap_now" in
        "" | *[!0-9]*)
          echo "amdgpu-power-profile: $bdf power1_cap files are missing or not numeric" \
            "(min='$cap_min' max='$cap_max' cap='$cap_now')" >&2
          failures=$((failures + 1))
          return
          ;;
      esac

      if [ "$cap_min" -gt "$target_uw" ]; then
        echo "amdgpu-power-profile: $bdf power1_cap_min is $(( cap_min / 1000000 )) W," \
          "above the ${toString powerCapWatts} W target. The patched kernel is not running." >&2
        failures=$((failures + 1))
        return
      fi
      if [ "$cap_max" -lt "$target_uw" ]; then
        echo "amdgpu-power-profile: $bdf power1_cap_max is $(( cap_max / 1000000 )) W," \
          "below the ${toString powerCapWatts} W target" >&2
        failures=$((failures + 1))
        return
      fi

      if [ "$cap_now" = "$target_uw" ]; then
        echo "amdgpu-power-profile: $bdf power1_cap=${toString powerCapWatts} W verified"
        return
      fi

      if ! ${pkgs.coreutils}/bin/printf '%s\n' "$target_uw" > "$cap_file"; then
        echo "amdgpu-power-profile: $bdf could not write power1_cap ${toString powerCapWatts} W" >&2
        failures=$((failures + 1))
        return
      fi
      cap_now="$(sysfs_read "$cap_file")"
      if [ "$cap_now" != "$target_uw" ]; then
        echo "amdgpu-power-profile: $bdf power1_cap readback is '$cap_now', expected $target_uw" >&2
        failures=$((failures + 1))
        return
      fi
      echo "amdgpu-power-profile: $bdf power1_cap=${toString powerCapWatts} W verified"
    }

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

      # The driver can expose the PCI device before its PowerPlay table is
      # readable. Wait for that boot race before applying the measured profile.
      pp_table="$dev/pp_table"
      pp_table_waits=0
      while [ ! -r "$pp_table" ] && [ "$pp_table_waits" -lt 120 ]; do
        ${pkgs.coreutils}/bin/sleep 1
        pp_table_waits=$((pp_table_waits + 1))
      done
      if [ ! -r "$pp_table" ]; then
        echo "amdgpu-power-profile: $bdf pp_table stayed unreadable for 120 seconds" >&2
        failures=$((failures + 1))
        continue
      fi
      table_hash="$(${pkgs.coreutils}/bin/sha256sum "$pp_table" | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
      if ! ${pkgs.gnugrep}/bin/grep -Fqx "$table_hash" <<'ACCEPTED_PP_TABLE_HASHES'
${lib.concatStringsSep "\n" acceptedPpTableSha256}
ACCEPTED_PP_TABLE_HASHES
      then
        echo "amdgpu-power-profile: $bdf PowerPlay table hash $table_hash is not in the reviewed allowlist" >&2
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

      # The cap step has its own verification. A failure leaves the written
      # value in place, as for the profile, and the unit still fails loudly.
      apply_power_cap "$bdf" "$dev"
    done

    if [ "$failures" -ne 0 ]; then
      echo "amdgpu-power-profile: $failures card(s) failed; refusing to report success" >&2
      exit 1
    fi
  '';
in
{
  # The profile and the ${toString powerCapWatts} W power cap are measured
  # settings, applied at the system level so that every benchmark sees the same
  # controls. Nothing else here changes clocks, the voltage offset, or the
  # PowerPlay table. An experiment can hold a different cap with
  # ${powerCapHoldFile}.
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
    power_cap_w=${toString powerCapWatts}
    power_cap_hold_file=${powerCapHoldFile}
  '';

  # Tools create the hold file here. Nothing else creates this directory.
  systemd.tmpfiles.rules = [ "d /run/nix-meta 0755 root root -" ];

  systemd.services.amdgpu-power-profile = {
    description = "Select the measured AMD GPU power profile (${toString powerProfile} ${powerProfileName}) and ${toString powerCapWatts} W power cap";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = applyProfile;
      TimeoutStartSec = "5min";
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
    description = "Re-assert and verify the AMD GPU power profile and power cap";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = applyProfile;
    };
  };
}
