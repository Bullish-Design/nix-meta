#!/usr/bin/env bash
set -Eeuo pipefail

BDF=""
TABLE=""
EXPECTED_CURRENT_SHA="87adbd7dec9615e6455fed3ef31b468f5c49063e40f27061f672b06b057c7784"
EXPECTED_TARGET_SHA="13309ea2cc3c288f4acb105dd0e8a33a3fb712423d6febf3f401c1720d7f4db2"

usage() { echo "usage: $0 --bdf 0000:19:00.0 --table /path/to/table.pp_table" >&2; exit 3; }
while (($#)); do
  case "$1" in
    --bdf) BDF="$2"; shift 2;;
    --table) TABLE="$2"; shift 2;;
    --expected-current-sha) EXPECTED_CURRENT_SHA="$2"; shift 2;;
    --expected-target-sha) EXPECTED_TARGET_SHA="$2"; shift 2;;
    -h|--help) usage;;
    *) usage;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "!! must run as root" >&2; exit 2; }
[[ "$BDF" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]+$ ]] || usage
[[ -r "$TABLE" ]] || { echo "!! table is not readable: $TABLE" >&2; exit 2; }

PCI="/sys/bus/pci/devices/$BDF"
DRIVER="$PCI/driver"
PP="$PCI/pp_table"
for n in {1..60}; do [[ -d "$PCI" ]] && break; sleep 1; done
[[ -d "$PCI" ]] || { echo "!! PCI function did not appear: $BDF" >&2; exit 1; }
for f in vendor device subsystem_vendor subsystem_device; do
  [[ -r "$PCI/$f" ]] || { echo "!! missing PCI identity: $PCI/$f" >&2; exit 2; }
done
[[ -r "$PP" && -w "$PP" ]] || { echo "!! pp_table is not readable and writable: $PP" >&2; exit 2; }
for n in {1..30}; do [[ -L "$DRIVER" ]] && break; sleep 1; done
[[ "$(readlink -f "$DRIVER")" == /sys/bus/pci/drivers/amdgpu ]] || {
  echo "!! refusing: $BDF is not bound to amdgpu" >&2; exit 1;
}

check_id() {
  local name="$1" expected="$2" actual
  actual="$(cat "$PCI/$name")"
  [[ "$actual" == "$expected" ]] || {
    echo "!! refusing: $BDF $name=$actual, expected $expected" >&2; exit 1;
  }
}
check_id vendor 0x1002
check_id device 0x6860
check_id subsystem_vendor 0x1002
check_id subsystem_device 0x0c35

table_sha="$(sha256sum "$TABLE" | awk '{print $1}')"
[[ "$table_sha" == "$EXPECTED_TARGET_SHA" ]] || {
  echo "!! refusing: target table hash $table_sha is not the reviewed 150 W table" >&2; exit 1;
}
current_sha="$(sha256sum "$PP" | awk '{print $1}')"
if [[ "$current_sha" == "$EXPECTED_TARGET_SHA" ]]; then
  echo "OK: $BDF already has the reviewed 150 W table"; exit 0
fi
[[ "$current_sha" == "$EXPECTED_CURRENT_SHA" ]] || {
  echo "!! refusing: current table hash $current_sha is not the expected 110 W baseline" >&2; exit 1;
}
echo "Applying reviewed soft PowerPlay table to $BDF"
cat "$TABLE" > "$PP"
sleep 3
after_sha="$(sha256sum "$PP" | awk '{print $1}')"
[[ "$after_sha" == "$EXPECTED_TARGET_SHA" ]] || {
  echo "!! refusing: readback hash $after_sha does not match target" >&2; exit 1;
}
echo "OK: $BDF now has the reviewed 150 W table"
