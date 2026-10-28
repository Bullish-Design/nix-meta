#!/usr/bin/env bash

# Source this file. It loads the ARCTIC channels that drive the GPU duct fans
# and the fast-ramp fans (channel 6 and the exhaust). The NixOS module writes
# the lists to files from the same Nix values that the watchdog uses.

load_gpu_fan_channels() {
  local file="/etc/nix-meta/arctic-fan/gpu-duct-channels" ch
  GPU_FAN_CHANNELS=()
  if [ ! -r "$file" ]; then
    echo "FAIL: GPU duct channel list is not readable: $file" >&2
    return 1
  fi
  while IFS= read -r ch || [ -n "$ch" ]; do
    [ -n "$ch" ] || continue
    if ! [[ "$ch" =~ ^[0-9]+$ ]]; then
      echo "FAIL: invalid GPU duct channel in $file: $ch" >&2
      return 1
    fi
    GPU_FAN_CHANNELS+=("$ch")
  done < "$file"
  if [ "${#GPU_FAN_CHANNELS[@]}" -eq 0 ]; then
    echo "FAIL: no GPU duct channels in $file" >&2
    return 1
  fi
  echo "gpu_duct_channels=${GPU_FAN_CHANNELS[*]}"
}

# Load the fast-ramp fan channels (channel 6 and the exhaust) into
# FAST_RAMP_CHANNELS.
load_fast_ramp_channels() {
  local file="/etc/nix-meta/arctic-fan/fast-ramp-channels" ch
  FAST_RAMP_CHANNELS=()
  if [ ! -r "$file" ]; then
    echo "FAIL: fast-ramp channel list is not readable: $file" >&2
    return 1
  fi
  while IFS= read -r ch || [ -n "$ch" ]; do
    [ -n "$ch" ] || continue
    if ! [[ "$ch" =~ ^[0-9]+$ ]]; then
      echo "FAIL: invalid fast-ramp channel in $file: $ch" >&2
      return 1
    fi
    FAST_RAMP_CHANNELS+=("$ch")
  done < "$file"
  if [ "${#FAST_RAMP_CHANNELS[@]}" -eq 0 ]; then
    echo "FAIL: no fast-ramp channels in $file" >&2
    return 1
  fi
  echo "fast_ramp_channels=${FAST_RAMP_CHANNELS[*]}"
}

# True for a channel that the watchdog drives: a GPU duct channel or a
# fast-ramp channel. Every other channel has no fan and stays at 255.
is_managed_channel() {
  is_fast_ramp_channel "$1" && return 0
  is_gpu_channel "$1"
}

is_fast_ramp_channel() {
  local ch
  for ch in "${FAST_RAMP_CHANNELS[@]}"; do
    [ "$1" = "$ch" ] && return 0
  done
  return 1
}

is_gpu_channel() {
  local ch
  for ch in "${GPU_FAN_CHANNELS[@]}"; do
    [ "$1" = "$ch" ] && return 0
  done
  return 1
}

# Load a fan curve. The NixOS module writes each curve file from the same Nix
# value that generates the watchdog's curve functions, so the test scripts and
# the watchdog cannot drift apart. Each line is "<minJunctionMilliC> <pwm>",
# ordered from the hottest step to the coolest. The lines are curve points, not
# steps: the watchdog interpolates linearly between them.
# Arguments: file, name of the array to fill, label for messages.
load_curve_file() {
  local file="$1" label="$3" line min pwm
  local -n curve="$2"
  curve=()
  if [ ! -r "$file" ]; then
    echo "FAIL: $label fan curve is not readable: $file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    min="${line%% *}"
    pwm="${line##* }"
    if ! [[ "$min" =~ ^[0-9]+$ ]] || ! [[ "$pwm" =~ ^[0-9]+$ ]]; then
      echo "FAIL: invalid curve step in $file: $line" >&2
      return 1
    fi
    curve+=("$min $pwm")
  done < "$file"
  if [ "${#curve[@]}" -eq 0 ]; then
    echo "FAIL: $label fan curve in $file is empty" >&2
    return 1
  fi
  echo "${label// /_}_fan_curve_steps=${#curve[@]}"
}

load_gpu_fan_curve() {
  load_curve_file /etc/nix-meta/arctic-fan/gpu-curve GPU_FAN_CURVE "GPU duct"
}

load_fast_ramp_curve() {
  load_curve_file /etc/nix-meta/arctic-fan/fast-ramp-curve FAST_RAMP_CURVE "fast-ramp"
}

# Load the two constants that shape the watchdog curve. The NixOS module writes
# each file from the Nix value that the watchdog uses.
#   lead-in-milli-c: the idle floor point sits this far below the next point.
#   hysteresis-milli-c: the command falls to the curve only once the smoothed
#     temperature is this far below the point that set it.
load_curve_constants() {
  local name file value
  for name in lead-in-milli-c hysteresis-milli-c; do
    file="/etc/nix-meta/arctic-fan/$name"
    if [ ! -r "$file" ]; then
      echo "FAIL: curve constant is not readable: $file" >&2
      return 1
    fi
    value="$(cat "$file")"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
      echo "FAIL: invalid curve constant in $file: $value" >&2
      return 1
    fi
    case "$name" in
      lead-in-milli-c) CURVE_LEAD_IN_MILLI_C="$value" ;;
      hysteresis-milli-c) CURVE_HYSTERESIS_MILLI_C="$value" ;;
    esac
  done
  echo "curve_lead_in_mC=$CURVE_LEAD_IN_MILLI_C curve_hysteresis_mC=$CURVE_HYSTERESIS_MILLI_C"
}

# PWM that the watchdog curve function gives for a temperature. It repeats the
# math of mkCurveFunction in the NixOS module: the idle floor point moves
# CURVE_LEAD_IN_MILLI_C below the next point, then the PWM is linear between the
# two surrounding points (integer math). Below the lowest point it gives the
# floor PWM. At or above the hottest point it gives that point's PWM.
# Arguments: temperature in milli-degrees C, name of the curve array.
curve_interp_pwm_in() {
  local temp="$1" i n min pwm hi_min hi_pwm
  local -n curve="$2"
  local -a mins=() pwms=()
  n="${#curve[@]}"
  for ((i = 0; i < n; i++)); do
    mins+=("${curve[i]%% *}")
    pwms+=("${curve[i]##* }")
  done
  if [ "$n" -ge 2 ]; then
    min=$((mins[n - 2] - CURVE_LEAD_IN_MILLI_C))
    [ "$min" -lt 0 ] && min=0
    mins[n - 1]="$min"
  fi
  for ((i = 0; i < n; i++)); do
    min="${mins[i]}"
    pwm="${pwms[i]}"
    [ "$temp" -ge "$min" ] || continue
    if [ "$i" -eq 0 ]; then
      echo "$pwm"
    else
      hi_min="${mins[i - 1]}"
      hi_pwm="${pwms[i - 1]}"
      echo $((pwm + (hi_pwm - pwm) * (temp - min) / (hi_min - min)))
    fi
    return 0
  done
  echo "${pwms[n - 1]}"
}

# Allowed commanded PWM range for a control temperature: "low high".
# The watchdog commands a value between the curve at the temperature and the
# curve at the temperature plus the hysteresis. After a fall from safe high it
# holds the upper value until the temperature drops by the hysteresis.
# Arguments: control temperature in milli-degrees C, name of the curve array.
curve_expected_range_in() {
  local low high
  low="$(curve_interp_pwm_in "$1" "$2")" || return 1
  high="$(curve_interp_pwm_in "$(($1 + CURVE_HYSTERESIS_MILLI_C))" "$2")" || return 1
  echo "$low $high"
}

curve_expected_range() {
  curve_expected_range_in "$1" GPU_FAN_CURVE
}

curve_expected_fast_ramp_range() {
  curve_expected_range_in "$1" FAST_RAMP_CURVE
}
