#!/nix/store/zh1ijdhb6gng1509b1zrilb6xlzx60j6-bash-5.3p9/bin/bash
    set -u

    safe_high() {
      if ! $FAKE/bin/arctic-fans-100; then
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
      for h in $FAKE/sys/class/hwmon/hwmon*; do
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
          sensor="${label%_label}_input"
          [ -r "$sensor" ] || continue
          printf '%s\n' "$sensor"
          return 0
        done
      done
      return 1
    }

    # Fan curve for both GPU duct fans, generated from `selectedFanCurve` in
    # this module's `let` block. Each step applies from its lower bound up to
    # the next bound. Values are PWM. The test scripts read the same curve from
    # /etc/nix-meta/arctic-fan/gpu-curve, so the two cannot drift apart.
curve_pwm() {
  junction="$1"
    if [ "$junction" -ge 0 ]; then
  printf '%s\n' 255
  else
    printf '%s\n' 255
  fi
}


    # Thresholds for the fan failure latch. A GPU fan below min_running_rpm for
    # stall_samples consecutive samples is failed. Startup_grace_samples skips
    # the first samples while the fans start.
    min_running_rpm=500
    stall_samples=3
    startup_grace_samples=5

    declare -A pwm_now=() fan_rpm=() strikes=() failed=()
    gpu_channel_list="2 3"
    gpu_channel_count=0
    for ch in 2 3; do
      strikes[$ch]=0
      failed[$ch]=0
      gpu_channel_count=$((gpu_channel_count + 1))
    done

    # Write one value to every GPU duct channel, then read each channel back.
    write_gpu_pwm() {
      local arctic="$1" value="$2" ch readback
      for ch in 2 3; do
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
    $FAKE/bin/systemd-notify --ready
    startup_waits=0
    while ! $FAKE/bin/systemctl is-active --quiet coolercontrold.service; do
      if [ "$startup_waits" -ge 180 ]; then
        echo "CoolerControl did not start after watchdog readiness" >&2
        exit 1
      fi
      startup_waits=$((startup_waits + 1))
      /nix/store/sr26flm2nkfa12dkrwj2630kqsfakky4-coreutils-9.11/bin/sleep 0.5
    done

    samples=0
    cooldown_samples=0
    while :; do
      samples=$((samples + 1))
      if ! $FAKE/bin/systemctl is-active --quiet coolercontrold.service; then
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
        channel="${pwm##*/pwm}"
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

      for ch in 2 3; do
        if [ ! -r "$arctic/pwm$ch" ] || [ ! -r "$arctic/fan${ch}_input" ]; then
          echo "GPU duct channel $ch is missing its PWM or tach attribute; forcing safe high" >&2
          exit 1
        fi
      done

      # Read every GPU tach. A read error or invalid value forces safe high.
      # A low tach value counts toward the stall latch for that channel.
      for ch in 2 3; do
        if ! rpm="$(cat "$arctic/fan${ch}_input")"; then
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
          && [ "${strikes[$ch]}" -ge "$stall_samples" ] \
          && [ "${failed[$ch]}" -eq 0 ]; then
          failed[$ch]=1
          echo "CRITICAL: GPU duct channel $ch stopped at $rpm RPM; latched as failed" >&2
        fi
      done

      failed_count=0
      for ch in 2 3; do
        if [ "${failed[$ch]}" -ne 0 ]; then
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
      for bdf in 0000:19:00.0 0000:67:00.0; do
        pci="$FAKE/pci/$bdf"
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
      for ch in 2 3; do
        if [ "$target_pwm" -gt "${pwm_now[$ch]}" ]; then
          needs_up=1
        fi
        if [ "$target_pwm" -lt "${pwm_now[$ch]}" ]; then
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
      for ch in 2 3; do
        detail="$detail channel$ch(pwm=${pwm_now[$ch]} rpm=${fan_rpm[$ch]} failed=${failed[$ch]})"
      done

      printf 'state=%s target_pwm=%s max_gpu_junction_mC=%s\n' "$state" "$target_pwm" "$max_junction" \
        > $FAKE/status || echo "could not write $FAKE/status" >&2
      $FAKE/bin/systemd-notify --status="$state target_pwm=$target_pwm" || true
      echo "ARCTIC watchdog: state=$state max_gpu_junction_mC=$max_junction target_pwm=$target_pwm cooldown_samples=$cooldown_samples$detail"
      /nix/store/sr26flm2nkfa12dkrwj2630kqsfakky4-coreutils-9.11/bin/sleep 2
    done

