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
