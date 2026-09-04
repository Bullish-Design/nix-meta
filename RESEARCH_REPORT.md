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

## Fan curve status

No final fan curve is enabled. CoolerControl remains the normal controller, and
the watchdog provides fail-high supervision. After the live acceptance sequence
passes, tune only `pwm1` from the maximum of the two GPU junction temperatures.
Use the measured PWM/RPM response, hysteresis, delayed ramp-down, fast ramp-up,
and full duct speed before 75--80 C. Keep unused channels at `255`.

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
