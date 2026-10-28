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
# ordered from the hottest step to the coolest.
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

# Expected PWM for a maximum junction reading from a loaded curve.
# Arguments: junction, name of the curve array.
curve_expected_pwm_in() {
  local junction="$1" step min pwm
  local -n curve="$2"
  for step in "${curve[@]}"; do
    min="${step%% *}"
    pwm="${step##* }"
    if [ "$junction" -ge "$min" ]; then
      echo "$pwm"
      return 0
    fi
  done
  echo "FAIL: no curve step matched junction $junction" >&2
  return 1
}

curve_expected_pwm() {
  curve_expected_pwm_in "$1" GPU_FAN_CURVE
}

curve_expected_fast_ramp_pwm() {
  curve_expected_pwm_in "$1" FAST_RAMP_CURVE
}
