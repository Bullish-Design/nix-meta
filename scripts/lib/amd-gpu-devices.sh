#!/usr/bin/env bash

load_amd_gpu_devices() {
  local devices_file="${NIX_META_AMD_GPU_DEVICES_FILE:-/etc/nix-meta/gpu-compute/amd-pci-devices}"
  local bdf
  AMD_GPU_BDFS=()

  if [ ! -r "$devices_file" ]; then
    echo "FAIL: AMD GPU PCI address file is not readable: $devices_file" >&2
    return 1
  fi

  while IFS= read -r bdf || [ -n "$bdf" ]; do
    [ -n "$bdf" ] || continue
    if [[ ! "$bdf" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
      echo "FAIL: invalid AMD GPU PCI address: $bdf" >&2
      return 1
    fi
    AMD_GPU_BDFS+=("$bdf")
  done < "$devices_file"

  if [ "${#AMD_GPU_BDFS[@]}" -eq 0 ]; then
    echo "FAIL: no AMD GPU PCI addresses are configured in $devices_file" >&2
    return 1
  fi

  return 0
}
