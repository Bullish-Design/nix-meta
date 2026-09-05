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
`180`). The script intentionally restored all channels to `255`; the watchdog
then resumed its normal conservative control.

CoolerControl's journal evidence confirms the `arctic_fan` device and all ten
fan inputs, but its initialization record shows only one AMD GPU location. The
kernel-level sensors for both GPUs pass; CoolerControl two-GPU visibility still
requires authenticated API/UI verification.

Not yet demonstrated: reboot persistence, synthetic sensor removal, USB
reconnect, and suspend/resume. CoolerControl's two-GPU visibility still needs
authenticated API/UI verification. These remain explicit risks; the tested
fail-high cases do not establish protection for every possible hardware or
power-management fault.

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

A later run using the live dynamic curve is recorded in
`artifacts/arctic-gpu-load-20260904T230333Z/load.log`. Both GPUs reached
`99--100%` utilization and the watchdog ramped the duct fan from `245` to
`255` as junction temperature rose. GPU0 reached exactly `80 C` at
`19:05:23`; the guard immediately terminated both tracked rocBLAS processes,
verified all ten ARCTIC channels at `255`, and exited `RESULT=FAIL`. This is a
deliberate safety cutoff, not a completed throughput result, and no benchmark
performance number should be inferred from it.

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

The generated configuration passed `nix flake check`; the exact server dry
build passed with kernel `6.18.38`. Live activation remains an operator action
via the privileged `nixos-rebuild switch` command.

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

## Persistent AMD/ROCm tools

`profiles/gpu-compute.nix` now owns the optional AMDGPU/ROCm tools used for
evaluation: `amdgpu_top`, `clinfo`, `amd-smi`,
`rocm-smi`, `rocminfo`, `rocm-bandwidth-test`, `rocblas-bench`, `rocgdb`, and
`rocprofiler`. This removes the need for an ad hoc `nix shell` after activation.

The server enables the profile's AMD flag. That flag sets `amdgpu.runpm=1` and
provides `amdgpu-headless-runtime-pm.service`. The service writes `auto` to
`power/control` for the two stable AMD PCI paths, so idle cards can enter
runtime suspend. The exact server build passed and evaluated the service and
kernel parameter. Activation was not completed in this run because sudo
required the operator password.

The GPU compute profile now has independent `amd.enable` and `nvidia.enable`
flags. Both default to `false`. The AMD-only server enables only the AMD flag
and does not enable the NVIDIA driver,
container toolkit, persistence service, or CDI generator. A host with NVIDIA
hardware can set the option to `true`.

### DPM explanation

AMDGPU DPM means Dynamic Power Management. PowerPlay exposes several selectable
clock states for each domain, principally shader/engine clock (`SCLK`) and
memory clock (`MCLK`). In `auto`, the driver and the GPU's System Management
Unit choose among those states according to workload, display/memory timing,
thermal limits, and power policy. The `*` in `pp_dpm_sclk` or `pp_dpm_mclk`
marks the state currently selected. The kernel documents `auto` as the mode
that dynamically selects the optimal profile; `low` and `high` force the
lowest/highest power states.

The idle observation was therefore more precise than “the GPU is busy”: both
GPUs reported instantaneous engine utilization `0`, but the device remained
runtime-active, `power/control=on`, `power_dpm_force_performance_level=auto`,
and retained elevated clock residency. A zero utilization sample means no
engine work at that instant; it does not guarantee that every clock domain has
entered its deepest idle state or that the device has runtime-suspended.

The preceding load run also caused a real state transition: both GPUs moved
between their Vega 10 DPM SCLK/MCLK levels while loaded, and the post-load
power stayed around `17--20 W` rather than the earlier `5--6 W`. Current
evidence does not identify a persistent userspace holder: no `/dev/dri` or
`/dev/kfd` holder was found in the later idle scan. CoolerControl's hwmon reads
are a candidate to rule out, but they are not proof of ownership. Display
requirements, runtime-PM references, and the driver's post-compute residency
decay remain the likely classes of cause. We have not changed DPM sysfs values
because forcing them could affect display stability and ROCm behavior.

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
- `machines/server.nix`
- `profiles/gpu-compute.nix`
- `scripts/arctic-fan-controller-test`
- `scripts/arctic-gpu-load-test`
- `.gitignore`
- `RESEARCH_REPORT.md`
- `artifacts/arctic-fan-controller-20260904T194223Z/*`
- `artifacts/arctic-fan-controller-test-20260904T211941Z/test.log`
- `artifacts/arctic-fan-controller-test-20260904T213352Z/test.log`

The earlier lane commit also contains the initial module packaging, server import,
CoolerControl ordering, and the 20260904T1820Z evidence set.
