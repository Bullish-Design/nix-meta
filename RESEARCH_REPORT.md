# ARCTIC Fan Controller investigation

Date: 2026-09-04

Target: `nixosConfigurations.server`

Lane: `arctic-fan-controller`

## Safety boundary

The running kernel is `6.18.38`. Nix evaluation reports `boot.kernelPatches = []`.
The evaluated `boot.extraModulePackages` contains the external ARCTIC package and
the selected NVIDIA package. No kernel replacement or kernel patch was added.

The live controller is USB `3904:f001` at Bus 001 Device 006. The native module
is loaded and binds through HID. The dynamic hwmon name is `arctic_fan`.

The controller has ten PWM attributes and ten tach attributes. The only connected
fan is the GPU duct fan on `pwm1`/`fan1`. Channels 2 through 10 are unused and
report zero tach. The physical Dell stock fan remains on the Dell motherboard
header and is reported by `dell_smm`, not by `arctic_fan`.

The stable controller device path is:

```text
/sys/devices/pci0000:00/0000:00:14.0/usb1/1-11/1-11:1.0/0003:3904:F001.0001
```

The stable GPU paths are:

```text
/sys/bus/pci/devices/0000:19:00.0
/sys/bus/pci/devices/0000:67:00.0
```

Both devices use `amdgpu`. Both expose junction as `temp2` and memory/HBM as
`temp3`. The watchdog resolves the `junction` label below each stable PCI path,
then computes the maximum junction value in millidegrees Celsius.

## Failure boundary

The prior activation failure occurred before the controller hwmon appeared.
`systemd-modules-load` used the booted generation, which did not contain the
new generation's external module. The activation service now checks `uname -r`,
loads the exact module path with `insmod`, and verifies `/proc/modules`.

The new safe-high helper searches by hwmon name, enumerates every exposed PWM
attribute, writes only `255`, attempts every channel even after a write error,
and verifies every readback. It never writes PWM 0.

The new independent watchdog starts with all channels high. It checks CoolerControl,
the dynamic ARCTIC hwmon, every readable PWM value, and both labelled GPU junction
sensors. It forces all channels high through the helper on read, control, sensor,
controller, or exit errors. Systemd supplies `ExecStopPost`, `Restart=on-failure`,
`RestartSec=10s`, and a six-start/60-second limit.

## Verification

The repeatable test harness is [scripts/arctic-fan-controller-test](scripts/arctic-fan-controller-test).
Run it from the repository with `sudo ./scripts/arctic-fan-controller-test`.
It writes a UTC artifact directory, stops on safety failures, and leaves the
controller high with CoolerControl stopped on the failure path.

Static verification passed:

- Nix parser check.
- Full pinned-environment build of `server`.
- Kernel derivation and final system closure under `6.18.38`.
- Module path under `lib/modules/6.18.38`.
- Module name `arctic_fan_controller`.
- Module alias `hid:b0003g*v00003904p0000F001`.
- Module vermagic `6.18.38 SMP preempt mod_unload`.
- Generated safe-high and watchdog shell syntax.
- Generated watchdog ordering after `arctic-fan-safe-high.service` and
  `coolercontrold.service`.
- Generated watchdog restart protection and `ExecStopPost`.

Prior live evidence recorded all ten ARCTIC PWM channels at `255`, `fan1` at
`3058 RPM`, and the other nine tach channels at zero. The saved controlled fan
test recorded `3029 RPM` at PWM `255` and `2352 RPM` at PWM `200`.

The root-authorized acceptance run is recorded in
`artifacts/arctic-fan-controller-test-20260904T211941Z/test.log`. It confirmed
kernel `6.18.38`, USB `3904:f001`, the bound native module, dynamic hwmon name
`arctic_fan`, ten PWM channels, ten tach channels, both stable PCI GPU sensor
paths, and localhost-only CoolerControl listeners. The exact module file was
found below the current-system symlink and reported native name
`arctic_fan_controller` with vermagic `6.18.38 SMP preempt mod_unload`.

The stop/ExecStopPost test passed, the SIGKILL crash test passed, and the
controlled response test passed without touching unused channels:

```text
pwm1/fan1: GPU duct fan
255 -> 3029 RPM
200 -> 2441 RPM
180 -> 2205 RPM
```

The run also found a lifecycle defect: the watchdog was started after
CoolerControl and its startup safe-high write overrode CoolerControl's saved
fan setting, leaving the controller at PWM 255 after restoration. The current
working tree changes the watchdog to systemd `Type=notify`, makes CoolerControl
require it, and starts CoolerControl only after the watchdog's initial safe-high
barrier. This requires a new build and acceptance run before relying on normal
fan control.

That follow-up rebuild and acceptance run is recorded in
`artifacts/arctic-fan-controller-test-20260904T213352Z/test.log`. The new
ordering was active, and stop/ExecStopPost, SIGKILL crash, and PWM response
tests passed again (`3058 RPM` at `255`, `2411 RPM` at `200`, and `2205 RPM` at
`180`). The script intentionally restored all channels to `255`; because no
fan curve or CoolerControl profile has been enabled yet, the final high value
is expected and does not demonstrate normal dynamic control.

CoolerControl's journal evidence confirms the `arctic_fan` device and all ten
fan inputs, but its initialization record shows only one AMD GPU location. The
kernel-level sensors for both GPUs pass; CoolerControl two-GPU visibility still
requires authenticated API/UI verification.

Not yet demonstrated: GPU load, reboot persistence, synthetic sensor removal,
USB reconnect, and suspend/resume. Do not enable a fan curve or claim complete
fail-high protection until those cases and the CoolerControl two-GPU check are
resolved or explicitly accepted as remaining risks.

## GPU load evidence

The requested dual-GPU load was run on 2026-09-04 with both AMD Vega 10 devices
at full utilization and the ARCTIC duct fan held at PWM `255`. The monitored
run is recorded in
`artifacts/arctic-gpu-load-20260904T221425Z/load.log`, with per-GPU rocBLAS
output in the adjacent `gpu0-rocblas.log` and `gpu1-rocblas.log` files.

Both tracked `rocblas-bench` processes exited `0`, and the monitor exited `0`.
GPU0 reached `76 C` junction and GPU1 reached `77 C` junction; neither reached
the `80 C` abort threshold. Memory temperatures reached approximately `73 C`.
Both GPUs sustained `99--100%` utilization at roughly `100--113 W`, while
ARCTIC `pwm1` remained `255` and `fan1` remained approximately `3029--3058
RPM`. The final readback confirmed all ten ARCTIC channels at `255` and no
rocBLAS process remained.

An initial wrapper attempt at 18:13 aborted before meaningful work because of
a monitor predicate typo; both benchmark logs were empty and all channels
remained at `255`. The corrected run above is the authoritative load result.

## Fan curve implementation

The watchdog now controls only the confirmed GPU duct channel `pwm1`. CoolerControl
leaves the ARCTIC device unmanaged and provides the local monitoring UI. The
watchdog computes the maximum junction temperature from both stable PCI paths.

The first conservative curve is:

```text
maximum junction < 45 C: 180
45--49 C:                 200
50--54 C:                 215
55--59 C:                 230
60--64 C:                 245
65 C and above:          255
```

PWM 180 is the lowest tested value with a positive tach response. The watchdog
ramp-up is immediate. It requires five consecutive cool samples before a
ramp-down. It verifies every `pwm1` write. It rejects zero, invalid values, and
any unused channel below `255`. Every read, write, sensor, controller, or exit
failure forces all channels to `255`.

The generated configuration passed `nix flake check` and the exact server dry
build. Live activation still requires the operator to run the privileged
`nixos-rebuild switch` command.

## Post-load GPU idle power investigation

After the successful dual-GPU load, a read-only eight-sample idle poll found no
rocBLAS process and reported `gpu_busy_percent=0` on both GPUs. Power remained
approximately `17--20 W` per GPU. Both devices reported `power/control=on`,
runtime usage `2`, and `power_dpm_force_performance_level=auto`. GPU0 retained a
500 MHz memory state, and both GPUs retained elevated shader-clock states.

The observed state explains the higher post-load power, but it does not yet
prove which client holds the devices active. No DPM or runtime-power sysfs value
was changed. A `rocm-smi` monitor process existed during an earlier inspection
and was gone by the later poll. CoolerControl, display ownership, and runtime
power references remain candidates for follow-up. The safe next step is to
repeat the read-only poll with monitoring clients closed, then compare runtime
references and DPM residency. Do not force a GPU power state during fan testing.

## Primary references

- [Linux hwmon sysfs interface](https://docs.kernel.org/hwmon/sysfs-interface.html)
  defines dynamic hwmon discovery, privileged writable attributes, fan inputs,
  and PWM attributes.
- [systemd service documentation](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html)
  documents service restart and stop behavior used by the watchdog.
- [NixOS manual](https://nixos.org/manual/nixos/stable/#sec-linux-kernel)
  documents NixOS kernel configuration and external kernel modules.

## Changed files

- `machines/hardware/arctic-fan-controller.nix`
- `scripts/arctic-fan-controller-test`
- `RESEARCH_REPORT.md`
- `artifacts/arctic-fan-controller-20260904T194223Z/*`
- `artifacts/arctic-fan-controller-test-20260904T211941Z/test.log`
- `artifacts/arctic-fan-controller-test-20260904T213352Z/test.log`

The earlier lane commit also contains the initial module packaging, server import,
CoolerControl ordering, and the 20260904T1820Z evidence set.
