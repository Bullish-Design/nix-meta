# Dual ARCTIC GPU duct fans: investigation and change

**Date:** 2026-10-06 (host local time, EDT)
**Host:** `server` (kernel 6.18.38)
**Status:** Repository change is built and statically checked. The live
host still runs the old single-fan watchdog. Do not treat either new fan as
connected until you confirm the physical install (see Section 8).

## 1. Summary

- Two ARCTIC S4028-15K fans replace the single GPU duct fan.
- The live tach readings suggest channels 2 and 3 are the new fans. Channel 1
  reads 0 RPM. This is evidence only. The install is not confirmed by you.
- The watchdog now drives channels 2 and 3 as one GPU duct pair. Channels 1
  and 4 to 10 stay at PWM 255.
- The fan curve is flat at PWM 255 until a calibration sweep measures a
  stable lower value. The old PWM 180 curve is removed.
- A stalled fan latches as failed. The watchdog keeps all channels high and
  reports the state in `/run/arctic-fan/status`.
- No load or thermal test has run on the new fans. The router is still
  stopped. No thermal result exists for the dual-fan setup.

## 2. Verified hardware

Sources: distributor listings for the S4028-15K. The physical label has not
been read. Confirm the label before you rely on these values.

| Item | Value | Source | Verified on label |
|---|---|---|---|
| Fan model | ARCTIC S4028-15K, 40 x 40 x 28 mm | [teqex listing](https://shop.teqex.co.uk/arctic-s4028-15k-40-mm-server-fan-acfan00264a.html) | No |
| Rated voltage | 12 V DC | [dateks listing](https://www.dateks.lv/en/cenas/ventilatori/956075-arctic-s4028-15k-black) | No |
| Rated current | 0.47 A | same | No |
| Starting voltage | 4.5 V | same | No |
| Speed range | 1,400 to 15,000 RPM | same | No |
| Control | 4-pin PWM | same | No |
| Bearing | Fluid dynamic bearing | teqex listing | No |
| Cable | 0.4 m | same | No |
| Controller | ARCTIC Fan Controller, USB HID `3904:f001` | `lsusb` on host | Yes |
| Controller ports | 10 PWM and tach channels | sysfs on host | Yes |
| Port current | Up to 2 A per header | [vortez news](https://www.vortez.net/news_story/arctic_launches_fan_controller_with_independent_10_channel_pwm_control.html) | No |
| Total current | 4.5 A combined | same | No |
| Controller power | SATA power connector | same | No |

Startup current is not published. The 4.5 V starting voltage is a voltage,
not a current.

## 3. Electrical budget

Two fans at rated current: 2 x 0.47 A = 0.94 A at 12 V (about 11.3 W).

| Limit | Published value | Load | Margin |
|---|---|---|---|
| Per port | 2 A | 0.47 A rated per fan | About 4.3x |
| Combined | 4.5 A | 0.94 A rated for two fans | About 3.6 A |

Unresolved:

- The controller limits come from a news article. The ARCTIC manual was not
  checked.
- Startup current was not measured.
- Confirm which SATA lead powers the controller. It should be a dedicated
  PSU lead, not a shared chain with the drives.

## 4. Physical channel map

Read-only host state at the start of this work:

| Channel | PWM | Tach | State |
|---|---|---|---|
| 1 | 180 | 0 RPM | No spinning fan. Old duct fan removed, or failed. |
| 2 | 255 | 14,470 RPM | Spinning. Candidate new fan. |
| 3 | 255 | 15,029 RPM | Spinning. Candidate new fan. |
| 4 to 10 | 255 | 0 RPM | Unused. |

Observed on the host:

- `arctic_fan` is `hwmon2`. Device path:
  `/sys/devices/pci0000:00/0000:00:14.0/usb1/1-11/1-11:1.0/0003:3904:F001.0001`.
- The module `arctic_fan_controller` is loaded.
- `arctic-fan-watchdog`, `arctic-fan-safe-high`, `arctic-fan-module-load`,
  and `coolercontrold` are active.
- GPU junction: card0 (`0000:19:00.0`) 21 C. card1 (`0000:67:00.0`) 22 C.
- `inferference-router` is inactive.

Both 14,470 and 15,029 RPM fall within the S4028-15K range (rated 15,000 RPM).

Channel-to-fan mapping is still unproven. The sweep in Section 9 proves it.
Do not assume channel 3 drives the second fan only because it is free.

## 5. Current and proposed configuration

### Current (commit `c4ee219`)

- Watchdog controls `pwm1` only. The old curve runs from PWM 180 to 255.
- Channels 2 to 10 must stay at 255. Channel 2 and 3 fans are not controlled.
- Acceptance test expects `fan1` to spin and `fan2` to `fan10` to read 0 RPM.
- GPU load test checks `pwm1` between 180 and 255. It stops at 80 C.

### Proposed

- `gpuFanChannels = [ 2 3 ]` in `machines/hardware/arctic-fan-controller.nix`.
  The list is also written to `/etc/nix-meta/arctic-fan/gpu-duct-channels`.
- Curve (`curve_pwm`), max GPU junction to PWM, both fans. Each step applies
  from its lower bound up to the next:

  | Junction | PWM |
  |---|---|
  | below 30 C | 25 |
  | 30 to 40 C | 50 |
  | 40 to 45 C | 75 |
  | 45 to 50 C | 100 |
  | 50 to 55 C | 125 |
  | 55 to 60 C | 150 |
  | 60 to 65 C | 175 |
  | 65 to 70 C | 200 |
  | 70 to 75 C | 225 |
  | 75 C and above | 255 |

  Measured in the sweep: 255, 200, 150, 100, 50. Not yet measured: 25, 75,
  125, 175, 225. The sweep default now covers all ten values. The step
  choice is the owner's. The GPU heat response is untested.
- Channel rules: GPU channels hold a valid nonzero value. All other
  channels must read 255.
- Failure latch: a GPU tach below 500 RPM for 3 samples latches that channel
  as failed. Startup grace is 5 samples (about 10 s).
- Failure policy:
  - 0 failed: normal control. Target is the curve.
  - 1 failed: state `DEGRADED`. All channels held at 255.
  - 2 failed: state `NO_AIRFLOW`. All channels held at 255. The watchdog keeps
    running and logs `CRITICAL`.
- Status file: `/run/arctic-fan/status` (`RuntimeDirectory=arctic-fan`).
  Also reported through `systemd-notify --status`.

## 6. Files changed

| File | Change |
|---|---|
| `machines/hardware/arctic-fan-controller.nix` | Channel list, per-channel write and readback, tach latch, failed-state policy, status file, `/etc` channel list, assertion for two channels |
| `scripts/lib/arctic-gpu-fan-channels.sh` | New. Loads the channel list. Used by both test scripts |
| `scripts/arctic-fan-controller-test` | Per-channel mapping check, per-channel PWM sweep (255, 200, 150, 120, 100), curve-hold test, watchdog status check, updated NOT TESTED list |
| `scripts/arctic-gpu-load-test` | Per-channel PWM and tach check. Unused-channel check uses the list. Stop limit from `ARCTIC_GPU_STOP_MC` (default 80000) |
| `.scratch/projects/02-gpu-voltage-limiting/benchmark-card1.py` | Finds `arctic_fan` by name. Records each GPU channel PWM and RPM |
| `.scratch/projects/03-dual-arctic-gpu-fans/REPORT.md` | This report |
| `.scratch/projects/03-dual-arctic-gpu-fans/sim/` | Sandbox harness and logs |

Not changed:

- Root `RESEARCH_REPORT.md` and older `.scratch` records. They describe the
  old state and are history.
- `run-control-arm.sh` and `run-power-saving-soak.sh`. They check the watchdog
  only. No fan channel is named.
- The inference repo. A search found no fan or hwmon dependency.

## 7. Verification

| Check | Result |
|---|---|
| `nix-instantiate --parse` on the module | Pass |
| `nix eval` of the watchdog `ExecStart` | Pass |
| `bash -n` on the generated watchdog and on each changed shell script | Pass |
| ShellCheck on the generated watchdog | Pass (after one fix, `case` on a constant) |
| `nix build` of `nixosConfigurations.server` toplevel (no activation) | Pass |
| Built closure contains the channel file and `RuntimeDirectory=arctic-fan` | Pass |
| Sandbox watchdog scenarios (fake sysfs, 9 cases) | Pass. Results below |
| Acceptance test on the live host | Not run. Requires root and the physical install |
| GPU load test | Not run |
| Thermal comparison against old one-fan data | Not run |

Sandbox results. The harness (`sim/run.sh`) points the generated watchdog at a
fake sysfs tree. It does not touch the real controller.

| Case | Expected | Result |
|---|---|---|
| healthy | state OK, PWM 255 | state=OK, PWM 255 |
| fan 2 stalls, later recovers | DEGRADED, latch holds after recovery | DEGRADED, latch held, process running |
| fans 2 and 3 stall | NO_AIRFLOW, process keeps running | NO_AIRFLOW, process running |
| fan 3 tach file missing | exit, fail-high | exit 1, safe-high written |
| fan 3 tach value `abc` | exit, fail-high | exit 1, safe-high written |
| pwm1 (unused) set to 180 | exit, fail-high | exit 1, safe-high written |
| pwm2 set to 0 | exit, fail-high | exit 1, safe-high written |
| pwm2 write fails (read-only file) | exit, safe-high attempted | exit 1. Safe-high also failed (same file), so pwm2 stayed at 200 |
| CoolerControl inactive | exit, fail-high | exit 1, safe-high written |

Sandbox limit: the write-failure case shows that safe-high cannot repair a
channel that refuses writes. The real controller behavior is not tested.

Run the harness again:

```bash
bash .scratch/projects/03-dual-arctic-gpu-fans/sim/run.sh
```

It writes to `/tmp/arctic-sim/`. Edit the `FAKE` path inside `run.sh` if you
move the harness.

## 8. Live steps that need you

### 8.1 Confirm the physical install (required first)

Do this before any live step.

1. Read the S4028-15K label on each fan. Confirm model, rated voltage, and
   that the connector is 4-pin PWM.
2. Confirm which controller port each fan uses. Expect ports 2 and 3.
3. Confirm the old duct fan is unplugged from port 1, or tell me it stays.
4. Confirm the SATA power lead for the controller.
5. Reply with: `install complete, fans on ports 2 and 3`.

Stop condition: any fan on a port other than 2 or 3, or any fan on port 1.

### 8.2 Read-only check after install

```bash
H=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = arctic_fan ] && echo $h; done)
for c in 1 2 3 4; do echo "pwm$c=$(cat $H/pwm$c) fan$c=$(cat $H/fan${c}_input)"; done
systemctl is-active arctic-fan-watchdog coolercontrold
```

Expected: `fan2` and `fan3` above 0 RPM. `fan1` and `fan4` at 0 RPM.

### 8.3 Land, then deploy

The flake reads trunk. Land the lane first (Section 10).

```bash
sudo nixos-rebuild switch --flake 'git+file:///home/andrew/Documents/Projects/nix-meta?ref=refs/heads/main#server'
```

Expected effects:

- `arctic-fan-safe-high` writes 255 to all channels.
- The new watchdog starts. It holds channels 2 and 3 at 255.
- CoolerControl restarts after the watchdog.

Stop condition: `arctic-fan-safe-high` or `arctic-fan-watchdog` is not
active after the switch. Or `/run/arctic-fan/status` does not read `state=OK`
within 10 s.

Rollback: Section 11.

### 8.4 Acceptance test (root, idle GPUs)

```bash
sudo ./scripts/arctic-fan-controller-test --artifact-dir artifacts/arctic-fan-controller-test-$(date -u +%Y%m%dT%H%M%SZ)
```

Expected effects: the script stops CoolerControl and the watchdog. It writes
each sweep value to one channel at a time. Sweep: 255, 200, 150, 120, 100. It
restores all channels to 255 after each step. It restarts the services at the
end.

Stop conditions:

- Any `FAIL` line.
- A GPU channel at 0 RPM at PWM 255.
- Any GPU junction above 45 C. Note: the script does not check temperature.
  Stop with Ctrl-C if the GPUs heat up.

The sweep output is the calibration data. Read it with:

```bash
grep '^sweep channel=' artifacts/arctic-fan-controller-test-*/test.log
```

### 8.5 Supervised failure drill (idle, one fan)

1. Start the watchdog. Confirm `state=OK`.
2. Unplug fan on port 2 for about 15 s. Expected log line within about
   12 s: `CRITICAL: GPU duct channel 2 stopped`. Expected state:
   `DEGRADED`. Expected PWM: 255 on all channels.
3. Replug fan 2. The latch holds (`DEGRADED`).
4. Clear the latch: `sudo systemctl restart arctic-fan-watchdog`.

Stop condition: PWM below 255 on any channel while state is `DEGRADED`.
Rollback: `sudo systemctl restart arctic-fan-watchdog`.

### 8.6 Calibration (before any curve below 255)

1. Use the sweep output from 8.4.
2. For each channel, pick the lowest value with a stable RPM. Require at
   least 500 RPM and no stall in a repeat run.
3. Replace `curve_pwm` with measured steps. Add a lower value only after
   both fans pass at that value.
4. Re-run 8.4 and 8.5.

Do not add a value below 255 from the old MI25 curve.

### 8.7 GPU workload (after 8.4 and 8.5 pass)

Run only after your review. The GPU load script stops at 80 C by default.
For the experiment stop, set 72 C:

```bash
sudo ARCTIC_GPU_STOP_MC=72000 ./scripts/arctic-gpu-load-test
```

Expected effects: two rocBLAS jobs run on both GPUs. The script logs both
junctions, both PWM values, and both fan RPMs every 2 s.

Stop condition: junction reaches 72 C. The script kills the jobs and sets
all channels to 255.

Compare against the old single-fan data in
`artifacts/arctic-gpu-load-20260904T221425Z/load.log` (old fan, PWM 255).

The long-prompt workload stays blocked until the short workload passes.

## 9. Unresolved risks

1. **Noise.** The flat PWM 255 curve runs both fans at about 14,500 to
   15,000 RPM all the time. This is loud. Calibration (8.6) is the fix. This
   is your first decision.
2. **Low-PWM behavior unknown.** No measured spin-up value exists for the
   S4028-15K. The 500 RPM latch threshold is a guess until 8.4 runs.
3. **Controller limits unverified.** The 2 A and 4.5 A limits come from a news
   article. Startup current is not measured.
4. **Controller disconnect.** Unknown whether the fans hold their last PWM or
   go to full speed. Not tested. The watchdog exits on a missing hwmon, but
   it cannot write safe-high to a disconnected controller.
5. **Failed PWM write.** The sandbox shows safe-high cannot fix a read-only
   channel. The live controller behavior is untested.
6. **One fan failed.** The other fan keeps running at 255. The watchdog does
   not stop GPU work. Only the existing 80 C guard in `inferference` limits
   heat. That guard does not read fan state.
7. **Two fans failed.** The watchdog logs `NO_AIRFLOW` and keeps running. It
   does not stop GPU work. Owner decision needed: should the router stop
   automatically on `NO_AIRFLOW`? This requires a change in `inferference`.
8. **Old fan.** If the old duct fan is still on port 1, the acceptance test
   fails on the unused-channel check. This is intended.
9. **No thermal result.** The dual-fan setup has no measured temperature or
   airflow data.
10. **Acceptance test not run on the new fans.** Root, idle GPUs, and the
    physical install are required.
11. **Reboot persistence not tested.** The module load and channel list are
    expected to survive a reboot. Not verified.
12. **Skill not found.** The `build-run-investigation` skill named in the
    request is not in this repo or the user skill list. This report follows
    the investigation order from the request.

## 10. Commit and landing

Gitman lane `arctic-dual-fan` landed into `main` and pushed to origin at
`ebbb904eccbf214a4f42717e29643917f1343ec8`. Landing does not activate the
change. Section 8.3 does that.

## 11. Rollback

Software rollback (after a switch):

```bash
sudo nixos-rebuild switch --rollback
```

Or switch to the previous commit explicitly:

```bash
sudo nixos-rebuild switch --flake 'git+file:///home/andrew/Documents/Projects/nix-meta?rev=c4ee219a8698e0a100575165147e941b4834761d#server'
```

Expected effect: the old watchdog returns. It controls `pwm1` only. It
requires channels 2 to 10 at 255. New fans on ports 2 and 3 stay at 255.
This passes the old unused-channel check.

Physical rollback: move the fans back to the old wiring. The old watchdog
expects one fan on port 1.

Safe state at any time: `sudo arctic-fans-100` writes 255 to all channels.

## 12. Results, 2026-10-06

Final state of the change:

- Trunk commit `780be31`. Deployed generation matches the Nix config on trunk.
- Watchdog `state=OK`. Curve table as in Section 5.
- Restart limits now apply from `[Unit]`.

Measured per-fan speed, same run for both fans (RPM at each PWM):

| PWM | Channel 2 | Channel 3 |
|---|---|---|
| 255 | 14,588 | 15,058 |
| 225 | 13,235 | 13,735 |
| 200 | 12,088 | 12,647 |
| 175 | 11,000 | 11,500 |
| 150 | 9,588 | 10,058 |
| 125 | 8,205 | 8,529 |
| 100 | 6,647 | 6,941 |
| 75 | 4,941 | 5,205 |
| 50 | 3,411 | 3,529 |
| 25 | 1,617 | 1,705 |

Each channel changed only its own fan. The other fan stayed near its 255 speed.
No stall at any value down to 25.

Acceptance run: `artifacts/arctic-fan-controller-test-curve-20261006T180933Z/test.log`.
Result: `RESULT=INCOMPLETE`. All automated checks passed. Untested cases are listed in the log.

Earlier failed run: `artifacts/arctic-fan-controller-test-curve-20261006T175350Z/test.log`.
It failed on a test bug, fixed in `780be31`. The curve match passed in that run.

Still open before router use:

- Loaded GPU run with the 72 C stop. The owner runs this elsewhere.
- Reboot persistence.
- Controller unplug and USB reconnect.
- One or two fans stopped. The latch logs and holds channels at 255. Nothing stops GPU work.
