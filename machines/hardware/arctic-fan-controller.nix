{ config, lib, pkgs, ... }:

let
  gpuPciDevices = config.nix-meta.gpu-compute.amd.pciDevices;
  gpuPciDevicesForShell = lib.concatMapStringsSep " " lib.escapeShellArg gpuPciDevices;

  # ARCTIC ports that carry the five GPU duct fans (ARCTIC S4028-15K, ducted
  # into the two AMD V620 cards). Channel N drives pwmN and reports fanN_input.
  # These are the loudest fans in the case. They run slow while the GPUs are
  # cool and ramp with the hottest GPU sensor (junction or memory). Change
  # this list only after the physical channel map is verified with scripts/arctic-fan-controller-test.
  gpuFanChannels = [ 1 2 3 4 5 ];
  gpuFanChannelsForShell = lib.concatMapStringsSep " " toString gpuFanChannels;

  # Fast-ramp channels. These fans are quiet, so they follow one aggressive
  # curve and reach full duty before the GPUs get hot.
  #   6:  front fan, ducted over the outside of the two GPUs. About 3,058 RPM
  #       at PWM 255 (measured 2026-10-28).
  #   10: rear case exhaust fan. About 2,900 RPM at PWM 255.
  # The Dell exhaust fan is not here. The BIOS controls it.
  fastRampChannels = [ 6 10 ];
  fastRampChannelsForShell = lib.concatMapStringsSep " " toString fastRampChannels;

  # Measured RPM at PWM 255, one entry per fast-ramp channel. The module
  # estimates the RPM at the lowest curve PWM by linear scaling and refuses to
  # build if the estimate is below twice the stall latch (see assertions).
  fastRampRpmAt255 = { "6" = 3058; "10" = 2900; };

  # Every other ARCTIC channel (7 to 9) has no fan. The watchdog holds them at
  # PWM 255 and fails high if one reads anything else.
  managedChannelsForShell = "${gpuFanChannelsForShell} ${fastRampChannelsForShell}";

  # Named GPU duct fan curves. Each entry is a curve point: a hottest-sensor
  # temperature (the hottest of junction and memory over both cards), in
  # milli-degrees C, and a PWM value. The watchdog interpolates linearly
  # between points. Order each list from the hottest point to the coolest, and
  # end it with a 0 entry. The 0 entry is the idle floor: the curve holds its
  # PWM below the lead-in point (see leadInMilliC) and ramps from there to the
  # next point. At or above the hottest point, the curve gives that point's
  # PWM. PWM-to-RPM values come from the project 03 calibration sweep.
  fanCurves = {
    # Shipped default (owner goal 2026-10-28): quiet duct fans, with the
    # hottest sensor at or below about 70 C when it holds. Measured on card 0
    # at 8 lanes: 140 W gives junction 63 C and memory 68 C. 160 W gives
    # junction 67 C and memory 70 C. The curve is keyed on the hottest of
    # junction and memory, so the memory sensor sets the speed when it leads.
    # It reaches full duty at 73 C, under the 75 C experiment arm bound and
    # the 80 C machine guard.
    quiet = [
      { minC = 73000; pwm = 255; }
      { minC = 72000; pwm = 235; }
      { minC = 70000; pwm = 205; }
      { minC = 68000; pwm = 180; }
      { minC = 66000; pwm = 155; }
      { minC = 63000; pwm = 130; }
      { minC = 60000; pwm = 110; }
      { minC = 55000; pwm = 90; }
      { minC = 50000; pwm = 70; }
      { minC = 45000; pwm = 50; }
      { minC = 0; pwm = 25; }
    ];

    # Fixed 50% duty for the wait between experiment runs. Reachable at
    # runtime as fan-profile lease "cooldown". The curve does not depend on
    # the temperature. A fault or a raw reading at or above the safety
    # override temperature still drives the fans higher.
    cooldown = [
      { minC = 0; pwm = 128; }
    ];

    # Project 024 arm 1 (C-FULL). Flat maximum duty at every temperature. This
    # is an EXPERIMENT curve: it runs all five fans at up to about 15,000 RPM
    # continuously and is loud. It exists to put an upper bound on airflow, so
    # a long decode can be measured with no fan ramp in the result. Reachable
    # at runtime as fan-profile lease "flat-max" (see fanProfiles).
    full = [
      { minC = 0; pwm = 255; }
    ];

    # Project 024 arm 2 candidate (C-STEEP). Steeper than the default at every
    # step. It reaches full duty at 68 C instead of 73 C, so the fans are at
    # maximum before the hottest sensor nears 70 C. Keyed on the hottest of
    # junction and memory. Reachable at runtime as fan-profile lease
    # "curve-steep".
    steep = [
      { minC = 68000; pwm = 255; }
      { minC = 64000; pwm = 225; }
      { minC = 60000; pwm = 190; }
      { minC = 55000; pwm = 155; }
      { minC = 50000; pwm = 120; }
      { minC = 45000; pwm = 90; }
      { minC = 40000; pwm = 60; }
      { minC = 0; pwm = 25; }
    ];
  };

  # Fast-ramp fan curves (channels 6 and 10). Same format as fanCurves. These
  # fans are not noisy, so the aggressive curve idles at PWM 80 and reaches full
  # duty at 50 C, before the GPUs get hot. They follow the hottest of junction
  # and memory, like the duct fans. At PWM 80 the estimate is about
  # 960 RPM on channel 6 (3,058 x 80 / 255) and about 910 RPM on channel 10.
  # Both are well above the 300 RPM stall latch, so no channel needs a higher
  # minimum PWM.
  fastRampCurves = {
    aggressive = [
      { minC = 50000; pwm = 255; }
      { minC = 45000; pwm = 220; }
      { minC = 40000; pwm = 180; }
      { minC = 35000; pwm = 140; }
      { minC = 30000; pwm = 110; }
      { minC = 0; pwm = 80; }
    ];
    full = [
      { minC = 0; pwm = 255; }
    ];
    cooldown = [
      { minC = 0; pwm = 128; }
    ];
  };

  # The active GPU curve when no fan-profile lease is held. Change this one
  # name to switch the default.
  selectedFanCurveName = "quiet";
  selectedFanCurve = fanCurves.${selectedFanCurveName};

  # Fail at evaluation time rather than shipping a curve that cannot answer
  # every temperature or that commands a stopped fan.
  curveShapeOk = curve:
    let
      last = lib.last curve;
      descending = lib.all (i: (lib.elemAt curve i).minC > (lib.elemAt curve (i + 1)).minC)
        (lib.range 0 (lib.length curve - 2));
    in
    curve != [ ] && last.minC == 0 && descending;

  curveIsValidFor = curve:
    curveShapeOk curve && lib.all (e: e.pwm >= 1 && e.pwm <= 255) curve;

  curveIsValid = curveIsValidFor selectedFanCurve;

  # The fan-profile lease (project 030 `DESIGN.md` section 5.1,
  # `inferference.experiment.control`). An experiment never writes a PWM: it
  # writes `/run/arctic-fan/request` naming one of these profiles, and this
  # watchdog is the only thing that turns that into curves. "curve-default"
  # always resolves to whatever `selectedFanCurveName` names above, so a
  # request that is absent, expired, dead-owner, or unknown falls back to
  # exactly the shipped behaviour. Each profile names one curve for each of the
  # two fan groups: the five GPU duct fans ("gpu") and the fast-ramp fans
  # ("fast": channel 6 and the exhaust).
  fanProfiles = {
    "flat-max" = { gpu = "full"; fast = "full"; };
    "curve-default" = { gpu = selectedFanCurveName; fast = "aggressive"; };
    "curve-steep" = { gpu = "steep"; fast = "aggressive"; };
    "cooldown" = { gpu = "cooldown"; fast = "cooldown"; };
  };
  # Profiles that go straight to 255 with no rate limit (and "full-duty-fault").
  fullDutyProfiles = lib.filter (n: fanProfiles.${n}.gpu == "full") (builtins.attrNames fanProfiles);
  fullDutyProfilesForShell = lib.concatStringsSep " " ([ "full-duty-fault" ] ++ fullDutyProfiles);
  allowedProfiles = builtins.attrNames fanProfiles;
  allowedProfilesForShell = lib.concatStringsSep " " allowedProfiles;
  defaultProfile = "curve-default";

  # Every curve a lease profile can select must exist and be valid, not only
  # the one selected by default -- a lease can reach any of them at runtime.
  curveNamesNeeded = kind: lib.unique (map (p: p.${kind}) (builtins.attrValues fanProfiles));
  curveSets = { gpu = fanCurves; fast = fastRampCurves; };

  # Lead-in below the first real curve point, in milli-degrees C. The idle
  # floor (the minC = 0 entry) moves to this distance below the next point, so
  # the curve ramps from the floor PWM to that point instead of jumping.
  leadInMilliC = 5000;
  interpPoints = curve:
    let n = lib.length curve; in
    if n < 2 then curve
    else lib.init curve ++ [{
      minC = lib.max 0 ((lib.elemAt curve (n - 2)).minC - leadInMilliC);
      pwm = (lib.last curve).pwm;
    }];

  # Render one shell function per curve actually reachable through a lease
  # profile, named by group and curve rather than by profile so two profile
  # names that share a curve do not duplicate work. Each function maps a
  # temperature in milli-degrees C to a PWM value by linear interpolation
  # between the two points that surround it (integer math). Below the lowest
  # point it gives the floor PWM. At or above the hottest point it gives that
  # point's PWM.
  mkCurveFunction = kind: name: curve:
    let pts = interpPoints curve; in
    ''
    curve_${kind}_${name}() {
      local t="$1"
  '' + lib.concatImapStrings
    (i: e:
      let hi = if i == 1 then null else lib.elemAt pts (i - 2); in
      ''
      ${if i == 1 then "    if" else "    elif"} [ "$t" -ge ${toString e.minC} ]; then
        ${if hi == null
          then "printf '%s\\n' ${toString e.pwm}"
          else "printf '%s\\n' $(( ${toString e.pwm} + (${toString hi.pwm} - ${toString e.pwm}) * (t - ${toString e.minC}) / (${toString hi.minC} - ${toString e.minC}) ))"}
    '')
    pts
  + ''
      else
        printf '%s\n' ${toString (lib.last pts).pwm}
      fi
    }
  '';

  allCurveFunctions = lib.concatStrings (lib.mapAttrsToList
    (kind: sets: lib.concatMapStrings
      (name: mkCurveFunction kind name sets.${name})
      (curveNamesNeeded kind))
    curveSets);

  # One dispatch function per group, with one case arm per lease profile.
  # Generated from `fanProfiles` so the shell dispatch and the Nix-level
  # profile table can never drift apart. "full-duty-fault" is not a
  # selectable profile -- it is the synthetic name the fault branch below
  # reports -- and is handled before this table, never through it.
  mkDispatchFunction = kind: ''
    curve_${kind}_for_profile() {
      profile="$1"
      hottest="$2"
      case "$profile" in
        full-duty-fault) printf '%s\n' 255 ;;
  '' + lib.concatStrings (lib.mapAttrsToList
    (profile: p: "      ${profile}) curve_${kind}_${p.${kind}} \"$hottest\" ;;\n")
    fanProfiles)
  + ''
        *) curve_${kind}_${if kind == "gpu" then selectedFanCurveName else "aggressive"} "$hottest" ;;
      esac
    }
  '';

  curveDispatchFunctions = lib.concatMapStrings mkDispatchFunction [ "gpu" "fast" ];

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

  # This watchdog is the normal controller for the five GPU duct fans and the
  # fast-ramp fans (channel 6 and the exhaust). It starts high, uses the
  # configured GPU PCI paths, and returns high on every error. CoolerControl leaves the ARCTIC fans unmanaged; it
  # remains the localhost UI and hardware monitor. The watchdog never touches
  # the Dell fans. The BIOS controls them.
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
      # RuntimeDirectoryPreserve keeps the directory, so remove the status
      # file here. A reader then never sees the status of a dead watchdog.
      rm -f /run/arctic-fan/status
      exit "$status"
    }

    trap on_exit EXIT
    trap 'exit 143' HUP INT TERM

    # The runtime directory survives a restart (RuntimeDirectoryPreserve), so
    # drop a stale status file from the previous run. The first sample writes
    # a fresh one. Keep the request file: it is a fan lease.
    rm -f /run/arctic-fan/status

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

    # Find the amdgpu temperature input with the given label ("junction" or
    # "mem") in the hwmon directory of one PCI device.
    find_gpu_sensor() {
      pci="$1"
      want="$2"
      for h in "$pci"/hwmon/hwmon*; do
        [ -d "$h" ] || continue
        [ -r "$h/name" ] || continue
        [ "$(cat "$h/name")" = amdgpu ] || continue
        for label in "$h"/temp*_label; do
          [ -r "$label" ] || continue
          [ "$(cat "$label")" = "$want" ] || continue
          sensor="''${label%_label}_input"
          [ -r "$sensor" ] || continue
          printf '%s\n' "$sensor"
          return 0
        done
      done
      return 1
    }

    # Fan curves for the GPU duct fans and the fast-ramp fans, one shell function
    # per curve reachable through a fan-profile lease, generated from
    # `fanCurves`, `fastRampCurves` and `fanProfiles` in this module's `let`
    # block. Each function interpolates linearly between curve points.
    # Values are PWM. The test scripts read the same curves from
    # /etc/nix-meta/arctic-fan/, so the two cannot drift apart.
${allCurveFunctions}
${curveDispatchFunctions}

    # Thresholds for the fan failure latch. A fan below its minimum running RPM
    # for stall_samples consecutive samples is failed. Startup_grace_samples
    # skips the first samples while the fans start. The GPU duct fans reach
    # about 15,000 RPM at PWM 255 and about 1,500 RPM at their idle PWM. The
    # fast-ramp fans reach about 3,000 RPM at PWM 255 and about 900 RPM at
    # their idle PWM, so they get a lower threshold. Each channel has its own
    # strike counter and its own latch.
    gpu_min_running_rpm=500
    fast_min_running_rpm=300
    stall_samples=3
    startup_grace_samples=5

    fast_channel_list="${fastRampChannelsForShell}"
    gpu_channel_list="${gpuFanChannelsForShell}"
    managed_channel_list="${managedChannelsForShell}"

    # Anti-hunting controls. The sim rewrites ema_div and rate_step.
    #   ema_div: the smoothed temperature moves 1/ema_div of the way to the raw
    #     reading each loop (12 gives a time constant of about 24 s at 2 s).
    #   rate_step: the largest PWM change per loop, up or down.
    #   hysteresis_mC: the command follows the curve down only once the
    #     smoothed temperature is this far below the point that set it.
    #   raw_override_mC: at or above this raw reading, the watchdog skips
    #     smoothing, the rate limit, and the hysteresis.
    ema_div=12
    rate_step=6
    hysteresis_mC=3000
    raw_override_mC=72000
    full_duty_profiles=" ${fullDutyProfilesForShell} "
    avg_hottest=""

    declare -A pwm_now=() fan_rpm=() strikes=() failed=() min_rpm=()
    gpu_channel_count=0
    for ch in $managed_channel_list; do
      strikes[$ch]=0
      failed[$ch]=0
      min_rpm[$ch]=$fast_min_running_rpm
    done
    for ch in $gpu_channel_list; do
      min_rpm[$ch]=$gpu_min_running_rpm
      gpu_channel_count=$((gpu_channel_count + 1))
    done

    channel_label() {
      case " $gpu_channel_list " in
        *" $1 "*) printf 'GPU duct channel %s\n' "$1" ;;
        *) printf 'fast-ramp channel %s\n' "$1" ;;
      esac
    }

    # Write one value to each listed channel, then read each channel back.
    write_group_pwm() {
      local arctic="$1" value="$2" ch readback
      shift 2
      for ch in "$@"; do
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

    # Move one fan group toward its curve. Arguments: hwmon path, group name
    # (unused label), up target, down target, jump flag, then the channels.
    #   up target: the curve value at the control temperature. The command
    #     rises to it.
    #   down target: the curve value at the control temperature plus the
    #     hysteresis. The command falls to it, and only when it is lower.
    # Both moves are limited to rate_step per loop, unless the jump flag is 1.
    # A jump goes straight up.
    ramp_group() {
      local arctic="$1" up="$2" down="$3" jump="$4" ch cur_min=255 cur_max=0 new
      shift 5
      for ch in "$@"; do
        [ "''${pwm_now[$ch]}" -lt "$cur_min" ] && cur_min="''${pwm_now[$ch]}"
        [ "''${pwm_now[$ch]}" -gt "$cur_max" ] && cur_max="''${pwm_now[$ch]}"
      done
      if [ "$up" -gt "$cur_min" ]; then
        new="$up"
        if [ "$jump" -ne 1 ] && [ "$new" -gt $((cur_min + rate_step)) ]; then
          new=$((cur_min + rate_step))
        fi
        write_group_pwm "$arctic" "$new" "$@"
      elif [ "$down" -lt "$cur_max" ]; then
        new="$down"
        if [ "$new" -lt $((cur_max - rate_step)) ]; then
          new=$((cur_max - rate_step))
        fi
        write_group_pwm "$arctic" "$new" "$@"
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

    samples=0
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

      # Read every PWM channel. Managed channels (GPU duct and fast-ramp) must
      # hold a valid nonzero value. Every other channel (7 to 9, no fan) must
      # stay at 255.
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
        esac
        if [ "$value" -gt 255 ]; then
          echo "invalid PWM value in $pwm: $value" >&2
          exit 1
        fi
        case " $managed_channel_list " in
          *" $channel "*)
            if [ "$value" -eq 0 ]; then
              echo "$pwm is zero; forcing safe high" >&2
              exit 1
            fi
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

      for ch in $managed_channel_list; do
        if [ ! -r "$arctic/pwm$ch" ] || [ ! -r "$arctic/fan''${ch}_input" ]; then
          echo "$(channel_label "$ch") is missing its PWM or tach attribute; forcing safe high" >&2
          exit 1
        fi
      done

      # Read every managed tach. A read error or invalid value forces safe
      # high. A low tach value counts toward the stall latch for that channel.
      for ch in $managed_channel_list; do
        if ! rpm="$(cat "$arctic/fan''${ch}_input")"; then
          echo "tach read failed on $(channel_label "$ch"); forcing safe high" >&2
          exit 1
        fi
        case "$rpm" in
          ""|*[!0-9]*)
            echo "invalid tach value on $(channel_label "$ch"): $rpm" >&2
            exit 1
            ;;
        esac
        fan_rpm[$ch]="$rpm"
        if [ "$rpm" -lt "''${min_rpm[$ch]}" ]; then
          strikes[$ch]=$((strikes[$ch] + 1))
        else
          strikes[$ch]=0
        fi
        if [ "$samples" -gt "$startup_grace_samples" ] \
          && [ "''${strikes[$ch]}" -ge "$stall_samples" ] \
          && [ "''${failed[$ch]}" -eq 0 ]; then
          failed[$ch]=1
          echo "CRITICAL: $(channel_label "$ch") stopped at $rpm RPM; latched as failed" >&2
        fi
      done

      # State: NO_AIRFLOW when every GPU duct fan is failed. DEGRADED when
      # any GPU duct fan or any fast-ramp fan is failed. Otherwise OK.
      failed_count=0
      for ch in $gpu_channel_list; do
        if [ "''${failed[$ch]}" -ne 0 ]; then
          failed_count=$((failed_count + 1))
        fi
      done
      fast_failed_count=0
      for ch in $fast_channel_list; do
        if [ "''${failed[$ch]}" -ne 0 ]; then
          fast_failed_count=$((fast_failed_count + 1))
        fi
      done
      if [ "$failed_count" -ge "$gpu_channel_count" ]; then
        state=NO_AIRFLOW
      elif [ "$failed_count" -gt 0 ] || [ "$fast_failed_count" -gt 0 ]; then
        state=DEGRADED
      else
        state=OK
      fi

      # Read the junction and the memory sensor of every GPU. A missing,
      # unreadable, or non-numeric sensor forces safe high. The control input
      # is the hottest of all these values. max_junction (the hottest
      # junction) stays in the status line because the inferference runner
      # records it.
      max_junction=""
      max_hottest=""
      for bdf in ${gpuPciDevicesForShell}; do
        pci="/sys/bus/pci/devices/$bdf"
        for sensor_name in junction mem; do
          if ! sensor="$(find_gpu_sensor "$pci" "$sensor_name")"; then
            echo "GPU $sensor_name sensor missing at $pci; forcing safe high" >&2
            exit 1
          fi
          if ! value="$(cat "$sensor")"; then
            echo "GPU $sensor_name read failed at $sensor; forcing safe high" >&2
            exit 1
          fi
          case "$value" in
            ""|*[!0-9]*)
              echo "invalid GPU $sensor_name value at $sensor: $value" >&2
              exit 1
              ;;
          esac
          if [ "$sensor_name" = junction ] \
            && { [ -z "$max_junction" ] || [ "$value" -gt "$max_junction" ]; }; then
            max_junction="$value"
          fi
          if [ -z "$max_hottest" ] || [ "$value" -gt "$max_hottest" ]; then
            max_hottest="$value"
          fi
        done
      done

      # --- fan-profile lease arbitration (DESIGN.md section 5.1) ---
      # Mirrors inferference.experiment.control.arbitrate() exactly. This
      # watchdog is the sole authority over the actuator: the request file
      # only ever NAMES a wish. A fault always wins, even over a live lease.
      # Any failed fan, GPU duct or fast-ramp, is a fault.
      active_profile="${defaultProfile}"
      active_reason="no request"
      if [ "$failed_count" -gt 0 ] || [ "$fast_failed_count" -gt 0 ]; then
        active_profile="full-duty-fault"
        active_reason="fault override"
      elif [ -r /run/arctic-fan/request ]; then
        req_text="$(cat /run/arctic-fan/request 2>/dev/null)" || req_text=""
        req_profile="$(printf '%s\n' "$req_text" | sed -n 's/^profile=\(.*\)$/\1/p' | head -n1)"
        req_expires="$(printf '%s\n' "$req_text" | sed -n 's/^expires=\(.*\)$/\1/p' | head -n1)"
        req_owner_pid="$(printf '%s\n' "$req_text" | sed -n 's/^owner_pid=\(.*\)$/\1/p' | head -n1)"
        if [ -z "$req_profile" ] || [ -z "$req_expires" ] || [ -z "$req_owner_pid" ]; then
          active_profile="${defaultProfile}"
          active_reason="malformed request"
        else
          case " ${allowedProfilesForShell} " in
            *" $req_profile "*) profile_allowed=1 ;;
            *) profile_allowed=0 ;;
          esac
          expires_epoch="$(${pkgs.coreutils}/bin/date -d "$req_expires" +%s 2>/dev/null)" || expires_epoch=""
          now_epoch="$(${pkgs.coreutils}/bin/date +%s)"
          case "$req_owner_pid" in
            ""|*[!0-9]*) owner_alive=0 ;;
            *) if kill -0 "$req_owner_pid" 2>/dev/null; then owner_alive=1; else owner_alive=0; fi ;;
          esac
          if [ "$profile_allowed" -ne 1 ]; then
            active_profile="${defaultProfile}"
            active_reason="unknown profile ignored"
          elif [ -z "$expires_epoch" ] || [ "$expires_epoch" -le "$now_epoch" ] || [ "$owner_alive" -ne 1 ]; then
            active_profile="${defaultProfile}"
            active_reason="lease dropped"
          else
            active_profile="$req_profile"
            active_reason="requested"
          fi
        fi
      fi

      # Smooth the control temperature. The average starts at the first raw
      # reading. At or above raw_override_mC the raw reading drives the curves
      # at once, and the average resets to it.
      if [ -z "$avg_hottest" ]; then
        avg_hottest="$max_hottest"
      else
        avg_hottest=$((avg_hottest + (max_hottest - avg_hottest) / ema_div))
      fi
      override=0
      control_mC="$avg_hottest"
      if [ "$max_hottest" -ge "$raw_override_mC" ]; then
        override=1
        avg_hottest="$max_hottest"
        control_mC="$max_hottest"
      fi

      # A full-duty profile (a fault or flat-max) and the override jump
      # straight to their target. Everything else is rate limited.
      jump="$override"
      case "$full_duty_profiles" in
        *" $active_profile "*) jump=1 ;;
      esac

      target_pwm="$(curve_gpu_for_profile "$active_profile" "$control_mC")"
      down_pwm="$(curve_gpu_for_profile "$active_profile" "$((control_mC + hysteresis_mC))")"
      fast_target_pwm="$(curve_fast_for_profile "$active_profile" "$control_mC")"
      fast_down_pwm="$(curve_fast_for_profile "$active_profile" "$((control_mC + hysteresis_mC))")"
      if [ "$override" -eq 1 ]; then
        # The override demands at least the default curve at the raw reading,
        # even under a profile that holds a low fixed duty.
        floor_pwm="$(curve_gpu_for_profile "${defaultProfile}" "$max_hottest")"
        [ "$floor_pwm" -gt "$target_pwm" ] && target_pwm="$floor_pwm"
        floor_pwm="$(curve_fast_for_profile "${defaultProfile}" "$max_hottest")"
        [ "$floor_pwm" -gt "$fast_target_pwm" ] && fast_target_pwm="$floor_pwm"
      fi
      [ "$down_pwm" -lt "$target_pwm" ] && down_pwm="$target_pwm"
      [ "$fast_down_pwm" -lt "$fast_target_pwm" ] && fast_down_pwm="$fast_target_pwm"

      ramp_group "$arctic" "$target_pwm" "$down_pwm" "$jump" gpu $gpu_channel_list
      ramp_group "$arctic" "$fast_target_pwm" "$fast_down_pwm" "$jump" fast $fast_channel_list

      detail=""
      for ch in $gpu_channel_list; do
        detail="$detail channel$ch(pwm=''${pwm_now[$ch]} rpm=''${fan_rpm[$ch]} failed=''${failed[$ch]})"
      done
      for ch in $fast_channel_list; do
        detail="$detail fast$ch(target=$fast_target_pwm pwm=''${pwm_now[$ch]} rpm=''${fan_rpm[$ch]} failed=''${failed[$ch]})"
      done

      # The first four keys are an API: the inferference experiment runner
      # parses them. Add new keys only after them, never before or between.
      # max_gpu_junction_mC is the hottest junction. max_gpu_hottest_mC is the
      # hottest of junction and memory over both cards: the control input of
      # both curves. exhaust_pwm is the commanded PWM of the fast-ramp group
      # (channel 6 and the exhaust move together). The key keeps its old name
      # for parsers.
      # max_gpu_hottest_avg_mC is the smoothed value that drives the curves
      # (the raw value at or above the safety override). target_pwm is the
      # commanded PWM of the GPU duct group, after the rate limit and the
      # hysteresis. The curve value it moves toward is in the journal.
      printf 'state=%s target_pwm=%s max_gpu_junction_mC=%s profile=%s exhaust_pwm=%s max_gpu_hottest_mC=%s max_gpu_hottest_avg_mC=%s\n' \
        "$state" "''${pwm_now[''${gpu_channel_list%% *}]}" "$max_junction" "$active_profile" "''${pwm_now[''${fast_channel_list%% *}]}" "$max_hottest" "$avg_hottest" \
        > /run/arctic-fan/status || echo "could not write /run/arctic-fan/status" >&2
      ${pkgs.systemd}/bin/systemd-notify --status="$state target_pwm=''${pwm_now[''${gpu_channel_list%% *}]} profile=$active_profile" || true
      echo "ARCTIC watchdog: state=$state max_gpu_junction_mC=$max_junction max_gpu_hottest_mC=$max_hottest max_gpu_hottest_avg_mC=$avg_hottest target_pwm=$target_pwm active_profile=$active_profile reason=\"$active_reason\" override=$override$detail"
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
      assertion =
        let all = gpuFanChannels ++ fastRampChannels;
        in gpuFanChannels != [ ] && fastRampChannels != [ ]
          && lib.length (lib.unique all) == lib.length all
          && lib.all (c: c >= 1 && c <= 10) all;
      message = "The ARCTIC GPU duct channels and the fast-ramp channels must be distinct and in 1 to 10.";
    }
    {
      # Estimate each fast-ramp fan at the lowest PWM on every fast-ramp curve
      # by linear scaling from its RPM at PWM 255. Keep it at or above twice
      # the 300 RPM stall latch, so an idle fan never reads as stalled.
      assertion = lib.all
        (ch: lib.all
          (curve: lib.all
            (e: (fastRampRpmAt255.${toString ch} * e.pwm) / 255 >= 600)
            curve)
          (builtins.attrValues fastRampCurves))
        fastRampChannels;
      message = "A fast-ramp curve idles a fan below about 600 RPM, too close to the 300 RPM stall latch. Raise its minimum PWM.";
    }
    {
      assertion = fanCurves ? ${selectedFanCurveName};
      message = "Unknown ARCTIC GPU fan curve: ${selectedFanCurveName}.";
    }
    {
      assertion = curveIsValid;
      message =
        "The selected ARCTIC GPU fan curve '${selectedFanCurveName}' is invalid. "
        + "It must be non-empty, ordered from the hottest step to the coolest, "
        + "end with a minC = 0 step, and command PWM 1 to 255 at every step.";
    }
    {
      assertion = lib.all (kind: lib.all (name: curveSets.${kind} ? ${name}) (curveNamesNeeded kind))
        (builtins.attrNames curveSets);
      message = "A fan-profile lease names a curve that does not exist.";
    }
    {
      assertion = lib.all
        (kind: lib.all (name: curveIsValidFor curveSets.${kind}.${name}) (curveNamesNeeded kind))
        (builtins.attrNames curveSets);
      message = "One of the ARCTIC fan curves reachable through a fan-profile lease is invalid.";
    }
  ];

  boot.extraModulePackages = [ arcticFanController ];
  boot.kernelModules = [ "arctic_fan_controller" ];

  environment.systemPackages = [ allFansHigh ];

  # Test scripts read the same channel lists as the watchdog.
  environment.etc."nix-meta/arctic-fan/gpu-duct-channels".text =
    lib.concatMapStrings (channel: "${toString channel}\n") gpuFanChannels;
  environment.etc."nix-meta/arctic-fan/fast-ramp-channels".text =
    lib.concatMapStrings (channel: "${toString channel}\n") fastRampChannels;

  # Test scripts read the same curve as the watchdog. One line per step,
  # "<minHottestMilliC> <pwm>", hottest step first.
  environment.etc."nix-meta/arctic-fan/gpu-curve".text =
    lib.concatMapStrings (e: "${toString e.minC} ${toString e.pwm}\n") selectedFanCurve;
  environment.etc."nix-meta/arctic-fan/fast-ramp-curve".text =
    lib.concatMapStrings (e: "${toString e.minC} ${toString e.pwm}\n") fastRampCurves.aggressive;

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
    description = "Independent fail-high watchdog for ARCTIC GPU duct, front, and exhaust cooling";
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
      # Writes /run/arctic-fan/status and reads /run/arctic-fan/request. Group
      # "users" (the operator's primary group) plus 0775 lets an unprivileged
      # experiment request a fan-profile lease; the watchdog itself still runs
      # as root, so every hwmon/PWM write is unaffected by this group change.
      RuntimeDirectory = "arctic-fan";
      # Keep /run/arctic-fan when the unit stops or restarts, so a restart
      # does not delete the request file (a fan lease). The watchdog removes
      # the stale status file at start and at exit.
      RuntimeDirectoryPreserve = "yes";
      RuntimeDirectoryMode = "0775";
      Group = "users";
      ExecStart = fanWatchdog;
      ExecStopPost = "${allFansHigh}/bin/arctic-fans-100";
      Restart = "on-failure";
      RestartSec = "10s";
      TimeoutStopSec = "90s";
    };
  };
}
