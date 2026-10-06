#!/usr/bin/env bash

# Source this file. It loads the ARCTIC channels that drive the GPU duct fans.
# The NixOS module writes the list to this file from the same Nix value that
# the watchdog uses.

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
  if [ "${#GPU_FAN_CHANNELS[@]}" -ne 2 ]; then
    echo "FAIL: expected two GPU duct channels in $file, found ${#GPU_FAN_CHANNELS[@]}" >&2
    return 1
  fi
  echo "gpu_duct_channels=${GPU_FAN_CHANNELS[*]}"
}

is_gpu_channel() {
  local ch
  for ch in "${GPU_FAN_CHANNELS[@]}"; do
    [ "$1" = "$ch" ] && return 0
  done
  return 1
}

# Load the active GPU duct fan curve. The NixOS module writes this file from
# the same Nix value that generates the watchdog's curve_pwm function, so the
# test scripts and the watchdog cannot drift apart. Each line is
# "<minJunctionMilliC> <pwm>", ordered from the hottest step to the coolest.
load_gpu_fan_curve() {
  local file="/etc/nix-meta/arctic-fan/gpu-curve" line min pwm
  GPU_FAN_CURVE=()
  if [ ! -r "$file" ]; then
    echo "FAIL: GPU duct fan curve is not readable: $file" >&2
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
    GPU_FAN_CURVE+=("$min $pwm")
  done < "$file"
  if [ "${#GPU_FAN_CURVE[@]}" -eq 0 ]; then
    echo "FAIL: GPU duct fan curve in $file is empty" >&2
    return 1
  fi
  echo "gpu_fan_curve_steps=${#GPU_FAN_CURVE[@]}"
}

# Expected PWM for a maximum junction reading, from the loaded curve.
curve_expected_pwm() {
  local junction="$1" step min pwm
  for step in "${GPU_FAN_CURVE[@]}"; do
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
