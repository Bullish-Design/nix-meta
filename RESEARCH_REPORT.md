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

The fresh read-only live snapshot found `pwm1=150` and `pwm2` through `pwm10`
at `255`. CoolerControl is active and listens only on `127.0.0.1` and `::1` on
ports `11987` and `11988`. This is a safety failure for the requested sequence.
The session cannot authenticate `sudo`, so it cannot safely restore all channels
to `255` or run the required service-stop and PWM-response tests. No GPU load,
reboot, controller disconnect, module unload, or fan-curve activation occurred.

Do not claim complete fail-high protection until the root-authorized test sequence
demonstrates daemon stop, daemon crash, sensor loss, controller reconnect, and
suspend/resume behavior.

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
- `RESEARCH_REPORT.md`
- `artifacts/arctic-fan-controller-20260904T194223Z/*`

The earlier lane commit also contains the initial module packaging, server import,
CoolerControl ordering, and the 20260904T1820Z evidence set.
