#!/usr/bin/env bash
set -Eeuo pipefail

# Run one card1 control arm as root. Run the benchmark as andrew. Restore controls on exit.

arm=${1:-}
case "$arm" in
  low) target_level=low; target_profile=0 ;;
  manual-default) target_level=manual; target_profile=0 ;;
  power-saving) target_level=manual; target_profile=2 ;;
  *) echo "usage: sudo bash $0 {low|manual-default|power-saving}" >&2; exit 3 ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo 'Run this script as root with sudo.' >&2
  exit 2
fi

device=/sys/bus/pci/devices/0000:67:00.0
level_file=$device/power_dpm_force_performance_level
profile_file=$device/pp_power_profile_mode
offset_file=$device/pp_od_clk_voltage
benchmark=/home/andrew/Documents/Projects/nix-meta/.scratch/projects/02-gpu-voltage-limiting/benchmark-card1.py
inferference=/home/andrew/Documents/Projects/inferference
devenv_bin=/etc/profiles/per-user/andrew/bin/devenv
changed=0

[[ -x $devenv_bin && -r $benchmark ]] || {
  echo 'The benchmark or devenv command is unavailable.' >&2
  exit 2
}

selected_profile() {
  awk '/^[[:space:]]*[0-9]+[[:space:]].*\*:/ { print $1; exit }' "$profile_file"
}

offset() {
  sed -n '2p' "$offset_file"
}

restore() {
  result=$?
  trap - EXIT
  if ((changed)); then
    printf 'manual\n' > "$level_file" || result=1
    printf '0\n' > "$profile_file" || result=1
    printf 'auto\n' > "$level_file" || result=1
    if [[ $(cat "$level_file") != auto || $(selected_profile) != 0 || $(offset) != 0mV ]]; then
      echo 'Card1 controls did not return to auto, profile 0, and 0 mV.' >&2
      result=1
    else
      echo 'Card1 controls restored: auto, profile 0, 0 mV.'
    fi
  fi
  exit "$result"
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for pair in 'vendor:0x1002' 'device:0x73a1' 'subsystem_vendor:0x1002' 'subsystem_device:0x0e34'; do
  name=${pair%%:*}
  expected=${pair#*:}
  actual=$(cat "$device/$name")
  [[ $actual == "$expected" ]] || { echo "$name changed: $actual" >&2; exit 1; }
done
[[ $(readlink -f "$device/driver") == /sys/bus/pci/drivers/amdgpu ]] || {
  echo 'Card1 is not bound to amdgpu.' >&2
  exit 1
}
[[ $(sha256sum "$device/pp_table" | cut -d ' ' -f 1) == a6fc019fdada096422629293bee778e8857af3330fd2dc2de42dd9d9d921b1c8 ]] || {
  echo 'Card1 PowerPlay table differs from the measured baseline.' >&2
  exit 1
}
systemctl is-active --quiet arctic-fan-watchdog.service || {
  echo 'ARCTIC fan watchdog is not active.' >&2
  exit 1
}

original_level=$(cat "$level_file")
original_profile=$(selected_profile)
original_offset=$(offset)
echo "Card1 original controls: $original_level, profile $original_profile, $original_offset."
[[ $original_level == auto && $original_profile == 0 && $original_offset == 0mV ]] || {
  echo 'Card1 controls differ from the recorded baseline.' >&2
  exit 1
}

vram_used=$(cat "$device/mem_info_vram_used")
((vram_used < 1024 * 1024 * 1024)) || { echo 'Card1 VRAM is in use.' >&2; exit 1; }

junction_file=
for label in "$device"/hwmon/hwmon*/temp*_label; do
  [[ -r $label ]] || continue
  if [[ $(cat "$label") == junction ]]; then
    junction_file=${label%_label}_input
    break
  fi
done
[[ -n $junction_file ]] || { echo 'Card1 junction sensor is missing.' >&2; exit 1; }
(( $(cat "$junction_file") <= 30000 )) || { echo 'Card1 must cool to 30 C first.' >&2; exit 1; }

unit_state=$(runuser -u andrew -- env XDG_RUNTIME_DIR=/run/user/1000 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  systemctl --user is-active inferference-router.service || true)
[[ $unit_state == inactive ]] || { echo "Router state is $unit_state; expected inactive." >&2; exit 1; }

changed=1
printf '%s\n' "$target_level" > "$level_file"
if [[ $target_level == manual ]]; then
  printf '%s\n' "$target_profile" > "$profile_file"
fi
[[ $(cat "$level_file") == "$target_level" && $(selected_profile) == "$target_profile" ]] || {
  echo 'Card1 rejected the requested controls.' >&2
  exit 1
}
echo "Card1 test controls: $target_level, profile $target_profile, 0 mV."

cd "$inferference"
runuser -u andrew -- "$devenv_bin" shell -- python "$benchmark" "$arm" \
  --expected-performance-level "$target_level" --expected-profile "$target_profile"
