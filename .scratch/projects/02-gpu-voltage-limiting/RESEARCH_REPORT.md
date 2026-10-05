# V620 voltage and power investigation

**Date:** 2026-10-05 UTC  
**Status:** The owner selected a controlled card1 benchmark. The loaded baseline reached the separate 72 C stop. The approved `low` arm completed and restored its controls. It reduced heat but made decode too slow. Profile comparisons are pending.

## Target and boundary

Reduce card1 heat during sustained Qwen inference while retaining useful throughput. Keep the 80 C thermal guard and the router stopped until a controlled load is selected. This project does not change the router guard; project 022 owns that work. The planned comparison uses the same model, Q8_0 K/V cache, two slots, context, prompts, and starting temperature for every control setting.

## Read-only host findings

At 2026-10-05 UTC, the router user unit was `inactive (dead)` with no main process. Both V620 cards were idle at about 16 MiB VRAM. Card0 reported edge 21 C, junction 24 C, memory 22 C, and 8 W. Card1 reported edge 23 C, junction 25 C, memory 24 C, and 7 W. The ARCTIC blower reported PWM 180 and 2,264 RPM. These are separate reads, not a time-aligned loaded sample.

Both cards identify as PCI vendor `0x1002`, device `0x73a1`, subsystem vendor `0x1002`, and subsystem device `0x0e34`. Both expose a 4,096-byte `pp_table` with SHA256 `a6fc019fdada096422629293bee778e8857af3330fd2dc2de42dd9d9d921b1c8`. Both report `power1_cap_min = power1_cap = power1_cap_max = 250 W`, `power_dpm_force_performance_level = auto`, and `pp_power_profile_mode = 0 BOOTUP_DEFAULT`. Both expose `OD_VDDGFX_OFFSET: 0mV` followed by an empty `OD_RANGE`. Both `in0_input` values were 6 mV while idle. The voltage reading still needs a loaded check.

The running kernel has `amdgpu.ppfeaturemask=0xffffffff`. The current NixOS generation omits it because `profiles/gpu-compute.nix` enables that parameter only for MI25, while `machines/server.nix` selects V620. A reboot can therefore change the available OverDrive controls. A V620 voltage change needs an explicit boot parameter and a post-reboot readback check.

## What the empty voltage range means

The [Linux 6.18 Sienna Cichlid driver](https://github.com/torvalds/linux/blob/v6.18/drivers/gpu/drm/amd/pm/swsmu/smu11/sienna_cichlid_ppt.c#L1390-L1430) prints `OD_VDDGFX_OFFSET` independently of clock limits. Its `OD_RANGE` section prints only GFXCLK and UCLK ranges when the board exposes those capabilities. An empty range therefore does not establish a zero-voltage range. The same [driver's offset edit path](https://github.com/torvalds/linux/blob/v6.18/drivers/gpu/drm/amd/pm/swsmu/smu11/sienna_cichlid_ppt.c#L2430-L2451) casts the requested value to signed 16 bit and has no driver-side board-range check. The later firmware table import can still reject a value. The legal offset range for this V620 firmware remains unknown.

Both cards expose SMU firmware `0x003a5b00`, or 58.91.0. The driver requires firmware 58.41.0 or newer for this offset path, so both cards pass its version gate. This does not prove the firmware will accept a negative offset.

The [kernel power-control guide](https://docs.kernel.org/gpu/amdgpu/thermal.html) documents `vo <offset>` followed by `c` to commit, and `r` to reset OverDrive settings. It also requires `manual` performance mode before a power profile change. A profile experiment must record and restore both the profile and the performance mode.

## Prior mechanism and risk

`nix/mi25-power-table.nix` starts a root oneshot unit for each selected MI25. Its applier, `ci/runner/amdgpu-soft-power-table.sh`, checks the PCI vendor, device, subsystem identity, baseline table hash, and target table hash before writing. It then reads the table back and checks the target hash. The MI25 gate is specific to device `0x6860` and subsystem device `0x0c35`; it cannot be reused for V620. The V620 stock table has a different size and hash. A wrong soft PowerPlay table can hang a card. No V620 table is proposed or written.

The [Linux 6.18 power limit path](https://github.com/torvalds/linux/blob/v6.18/drivers/gpu/drm/amd/pm/swsmu/smu11/sienna_cichlid_ppt.c#L624-L675) derives the minimum cap from the board table's OverDrive power percentage when that feature is supported. The fixed 250 W range means that the live board table does not provide a lower cap through this interface. Editing a V620 soft table may expose a lower cap, but firmware acceptance needs controlled validation. The currently available low-power controls have a lower failure cost, so defer a soft-table design until their measured results are known.

The [Linux 6.18 table layout](https://github.com/torvalds/linux/blob/v6.18/drivers/gpu/drm/amd/pm/swsmu/inc/smu_v11_0_7_pptable.h) permits a read-only check of the 4,096-byte stock blob. Both card hashes match. Both blobs have OverDrive revision `0x81`, feature count 16, and setting count 30. All 32 capability bytes are zero, including `ODCAP_POWER_LIMIT` at index 3. The power percentage field at setting index 8 holds maximum 10 and minimum 7. The driver ignores these percentages because the capability byte is zero. This explains the observed 250 W minimum and maximum. If a reviewed table enabled only that capability, the driver's formula would request a 232.5 W lower bound and a 275 W upper bound. Firmware acceptance remains unknown. A useful lower cap may also require changing the lower percentage. Exposing a 275 W upper bound would create an owner-only safety decision, so do not try this as a first fix.

Project 021 measured 104 W with one idle Q8_0 slot and 147 W with two, at 31–36 C. Project 020 measured a 251–253 W peak and a thermal stop under longer Q8_0 work. Project 019 recorded near-cap prompt thermal trips. These histories suggest that burst work, rather than loaded idle, reaches the stock cap. They do not supply a matched V620 power-versus-throughput curve.

## Loaded baseline, 2026-10-05

The owner selected a controlled direct-server benchmark on card1. The exact command, model checksum, build manifest, requests, responses, and 0.25-second telemetry are in `/mnt/shared/ai/models/qwen3.8-27b-gguf/artifacts/2026-10-05T103343Z/02-v620-baseline/`. The runner confirmed PCI `0000:67:00.0`, 66/66 GPU layers, a 2,720 MiB Q8_0 K/V buffer, and two 40,960-token slots. The router stayed stopped. The card1 control state stayed `auto`, profile 0, and 0 mV offset.

| Measure | Baseline result |
| --- | ---: |
| Card1 starting junction | 25 C before launch; 24 C at first telemetry sample |
| 2,049-token prompt | 353.76 tokens/s; answer passed |
| Short decode | 18 tokens at 21.12 tokens/s |
| Longer decode | Stopped at 72 C after 767 debug-log tokens; no completed API response |
| Approximate partial long-decode rate | 20.1 tokens/s from debug timestamps; not a completed result |
| Peak card1 power | 252 W |
| Power during the 15–54 s window, dominated by decode | 213.4 W mean; 216 W median; 227 W maximum |
| Power during the hotter 30–54 s window | 217.9 W mean; 218 W median |
| Peak card1 edge, junction, memory | 66 C, 72 C, 54 C |
| Peak fan duty and tachometer | PWM 255; 3,058 RPM |
| Peak card1 VRAM and GTT rise | 19,555.7 MiB; 125.2 MiB |

The separate experiment monitor killed the exact test server at 72 C after about 54 seconds of telemetry. The repository guard remained at 80 C and did not trip. The process exited 137, so the longer response has no valid completed throughput. Card1 released its model VRAM, and the router user unit remained stopped.

The result changes the working heat hypothesis. Prefill touched the 250 W cap, but decode held about 218 W in the hot window. Loaded-idle power from project 021 is not a decode power measurement. A cap reduction could affect decode as well as prefill on this workload. The fan reached full duty as junction rose, leaving no curve headroom above 65 C.

`in0_input` moved from 6 mV at idle to a median 1,068 mV during the decode window. It therefore tracks activity on card1. This does not yet prove that it measures an applied OverDrive offset accurately; that needs a matched offset test.

## `low` control arm, 2026-10-05

The owner approved the card1 `low` arm. The owner ran the root wrapper from the host terminal. It used the same server, model, Q8_0 cache, two slots, context, and requests as the baseline. The full artifact is `/mnt/shared/ai/models/qwen3.8-27b-gguf/artifacts/2026-10-05T132950Z/02-v620-low/`.

| Measure | Baseline `auto` | `low` |
| --- | ---: | ---: |
| 2,049-token prompt | 353.76 tokens/s | 167.80 tokens/s |
| Short decode | 21.12 tokens/s | 1.82 tokens/s |
| Long decode | Stopped at 72 C | Timed out after 300 s |
| Junction near 54 s from first telemetry sample | 71–72 C | 44 C |
| Peak card1 power | 252 W | 173 W |
| Peak card1 junction | 72 C at experiment stop | 60 C |
| Peak fan speed | 3,058 RPM | 2,970 RPM |

The `low` arm kept the card below the 72 C experiment stop for more than five minutes. Its long request did not complete, so it has no valid completed long-decode rate. The short decode rate fell by 91.4%. The prompt rate fell by 52.6%. Both arms started near 24–25 C junction. Near 54 seconds from the first telemetry sample, `low` was 27–28 C cooler. This comparison uses the same elapsed time but different token progress because `low` is slower. The magnitude of the decode slowdown makes `low` unsuitable for normal serving. The benchmark released card1 model memory, and a live read after the root wrapper exited confirmed `auto`, profile 0, and 0 mV. The router stayed stopped.

## First cross-card cooling comparison

Project 020 ran the same server, model, Q8_0 cache, two slots, context, batch settings, and requests on card0. Its cool-start run began at 26 C junction and reached the 72 C experiment stop after about 53 seconds. The card1 baseline began at 25 C junction and reached 72 C after about 54 seconds. The 2,049-token prompt rates were 352.21 and 353.76 tokens/s, respectively. Both runs reached PWM 255 and 3,058 RPM. These results do not show a large card1 cooling deficit under this workload. They came from different days, and the card0 run had the production model loaded but idle on card1. The card0 run also lacks valid power telemetry. A paired comparison with both cards starting at the same temperature would be needed to rule out a smaller cooling difference.

## Control comparison plan

Use the same direct server, model, Q8_0 K/V cache, two slots, context, and fixed requests for each control arm. Keep the production router stopped. Record the exact command, 0.25-second power, temperature, clocks, voltage, fan, and request timings. Stop the exact test server at 72 C or a 512 MiB GTT rise. Allow the card to cool to 30 C or below before each arm.

The project 020 direct-server runner could not run unchanged: it binds card0 and requires the production router to be healthy. `benchmark-card1.py` adds explicit PCI identity and lease checks, a separate port, and a stopped-router check. The first baseline ran with all GPU controls at their original values.

The `low` comparison is complete. For profile tests, first measure `manual` with profile 0, then `manual` with `POWER_SAVING` profile 2. This separates the effect of `manual` from the profile. Test `COMPUTE` profile 5 only if a later result justifies its possible higher power. Record the initial mode and profile before each write; restore `auto` and profile 0 after each arm. A profile change that does not lower power or temperature at matched throughput is not a cooling fix.

`run-control-arm.sh` implements the three reversible arms. It requires PCI `0x1002:0x73a1`, subsystem `0x1002:0x0e34`, the baseline PowerPlay table hash, an active fan watchdog, the stopped router, free card1 VRAM, junction at or below 30 C, and original controls `auto`, profile 0, 0 mV. It writes only the performance level and power profile. It runs the benchmark as `andrew`, then restores `auto` and profile 0 through an exit trap. The script checks the restored values. An experiment thermal stop returns a nonzero status even when restoration succeeds.

The root-owned sysfs controls require an interactive `sudo` password. `sudo -n true` and the approved `sudo -n bash ... low` attempt returned `sudo: a password is required`. The owner approved and ran the `low` arm in the host terminal:

```sh
sudo bash /home/andrew/Documents/Projects/nix-meta/.scratch/projects/02-gpu-voltage-limiting/run-control-arm.sh low
```

The exact manual-default and power-saving arms use the same command with the final argument changed. Each run writes its own timestamped SSD artifact. The operator should confirm that the script prints the restored controls after each run. Do not start another arm until card1 junction returns to 30 C or below.

Only after the reversible controls are measured, probe voltage on idle card0. Confirm its original offset is 0 mV. Write a small negative pending value, such as `vo -25`, and check readback. Commit only if that first write succeeds. Check the committed readback, then reset with `r` and confirm 0 mV. Restore the prior performance mode. Expect firmware to accept the small offset or reject the commit cleanly; do not infer success from the sysfs write alone. A later loaded voltage comparison needs matched card and workload, power, temperature, throughput, and error checks.

## Open questions

- The owner selected a controlled direct-server benchmark. Its first loaded baseline reached the separate 72 C stop. `low` kept the card cooler but cut decode throughput by 91.4%.
- The V620 firmware's valid voltage offset range is unknown.
- `in0_input` tracks idle-to-load activity. Whether it tracks an applied voltage offset accurately remains unknown.
- Cross-day card0 and card1 runs reached 72 C at similar times. A paired run is needed to assess smaller cooling differences.
- The 250 W cap cannot be lowered through `power1_cap`. A V620 soft table may change that range, but its format and safe values need separate research and explicit approval for the exact blob.
- No runtime control setting or reboot has been applied in this investigation.
