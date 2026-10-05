# Kickoff: voltage-limit the V620 GPUs

Your job is to work out how to run the two Radeon Pro V620 cards in host
`server` at lower voltage or lower power, so card1 stops reaching 86 C under
sustained inference. Investigate, propose with measurements, get the owner's
approval, then implement.

**You are writing to GPU power and voltage registers.** Nothing here is
reversible by `gitman undo`. Two branch names in this fleet —
`recover-mi25-power-table` and `fix/restore-mi25-power-table` — say a power
table has already gone wrong once on this rig. Read that history before you
write anything.

## Why this task exists

Card1 runs a 27B model and reaches 83 to 86 C junction under load. A thermal
guard kills the inference router at 80 C, systemd restarts it, the model
reloads, and the card reheats — 18 kills in 30 minutes, 30 restarts total, on
2026-10-03. The router is currently **stopped**, so Hindsight has no model and
every agent session on this host is running without it.

The separate question of whether the 80 C guard limit is itself correct is
tracked in
`~/Documents/Projects/inferference/.scratch/projects/022-router-thermal-kill-loop/KICKOFF.md`.
**Read it, but do not solve it here.** This task is the other half: reduce the
heat the card produces, rather than raise the temperature we tolerate. The two
fixes compose; either alone may be enough.

## Hardware, verified 2026-10-05

Two AMD Radeon Pro V620, Navi 21, PCI `1002:73a1`. card0 = PCI `0000:19:00.0`
= hwmon5 = Vulkan0. card1 = PCI `0000:67:00.0` = hwmon6 = Vulkan1. Both
30,704 MiB. Qwen is resident on card1 when the router runs.

**Both cards are passively cooled and have no onboard fan.** `FAN_CONTROL` is
`disabled` in `pp_features`, and `rocm-smi` reporting `Fan: 0%` is meaningless.
All airflow comes from one external USB ARCTIC duct blower (hwmon2, HID
`3904:F001`) driven by `arctic-fan-watchdog.service` off a GPU-junction curve.
It was observed at `pwm1 = 255` — full duty — during the thermal loop, and at
`pwm1 = 180` with both cards idle. **Re-measure it under load before assuming
there is no cooling headroom left.**

Thermal limits from hwmon, identical on both cards: edge and junction
`crit = 100 C`, `emergency = 105 C`; memory `crit = 98 C`, `emergency = 103 C`.
So 86 C is well inside the hardware's own limits — the 80 C guard is a policy
choice, not a hardware ceiling.

## The lever survey — measured, not assumed

I read every relevant sysfs node on both cards. Do not re-derive this; verify
anything you intend to act on.

| Lever | State | Verdict |
|---|---|---|
| `power1_cap` | `cap = min = max = default = 250000000` µW on **both** cards; independently confirmed by project 020 | **Pinned.** No range, unmasked or not |
| `OD_VDDGFX_OFFSET` | present, `0mV`, but `OD_RANGE` is **empty** | The one voltage knob. Legal range unknown |
| `OD_SCLK` / `OD_MCLK` | **absent** from `pp_od_clk_voltage` entirely | Not available |
| `pp_dpm_sclk` | `0: 0Mhz *` and `1: 0Mhz *` — both "active" at 0 MHz | Not a usable ladder |
| `pp_features` | `DPM_GFXCLK (1): disabled`, `DPM_GFX_GPO (2): disabled`, `GFXOFF (20): disabled` | Explains the two rows above |
| `pp_power_profile_mode` | 7 profiles, `BOOTUP_DEFAULT*` selected | **Available now** |
| `power_dpm_force_performance_level` | `auto` | **Available now** |
| `pp_table` | writable, `rw-r--r-- root:root`, on both cards | **Available** — see below |

`pp_od_clk_voltage` verbatim on both cards:

```
OD_VDDGFX_OFFSET:
0mV
OD_RANGE:
```

Nothing follows `OD_RANGE:`. Whether that means "0 mV is the only legal value"
or "the range is simply unpopulated while `DPM_GFXCLK` is disabled" could not
be determined by reading. **Resolving that is your first technical question.**

`in0_label` is `vddgfx` and `in0_input` reads **6** on both cards, at idle.
Six millivolts is not a credible gfx rail voltage, and `rocm-smi --showvoltage`
returns the same number from the same node. So **do not validate a voltage
change against `in0_input` until you have confirmed it tracks load** — observe
it idle versus loaded first. If it never moves, you need a different success
measure, most likely power draw and temperature at fixed throughput.

## The thing nobody has noticed — fix this regardless

`profiles/gpu-compute.nix:133` reads:

```nix
(lib.mkIf (cfg.amd.enable && cfg.amd.model == "mi25") {
  # MI25 OverDrive and its reviewed soft PowerPlay table stay opt-in.
  boot.kernelParams = [ "amdgpu.ppfeaturemask=0xffffffff" ];
  services.inferference-mi25-power-table = { enable = true; cards = mi25Cards; };
})
```

`machines/server.nix:95` sets `model = "v620"`. **So neither the overdrive
unmask nor the power-table service applies to this host any more.**

Overdrive is nevertheless enabled right now:

```
/proc/cmdline                                 amdgpu.ppfeaturemask=0xffffffff
/sys/module/amdgpu/parameters/ppfeaturemask   0xffffffff
/run/booted-system/kernel-params              amdgpu.ppfeaturemask=0xffffffff
/run/current-system/kernel-params             (absent)
```

The running kernel booted from a generation that predates the `model`
conditional. The machine has not rebooted since. **The next reboot boots a
generation whose command line does not request it.** Whether overdrive
survives then depends on the amdgpu module's compiled-in default, which
`modinfo` describes as "all power features enabled (default)" but which was not
confirmed numerically against kernel 6.18.38.

Treat that as unresolved risk. If your fix depends on `pp_od_clk_voltage`, add
the explicit kernel parameter to the **v620** path rather than relying on a
default — otherwise your undervolt silently stops applying after a reboot, and
the card gets hot again with no obvious cause.

## Prior art — read before writing

- **`origin/amd-overdrive-unmask`** (`b79c7ea`, 2026-09-05) and
  **`origin/recover-mi25-power-table`** (`3f86123`, 2026-09-06) are **both
  already merged into trunk**. Their branch refs are stale pointers, not open
  work; `git diff origin/main...<branch>` is empty for each. Do not try to
  re-land them. `b79c7ea` added the overdrive unmask; `3f86123` added
  `nix/mi25-power-table.nix` plus the 150 W blob. Commit `8da9ac5`
  ("feat: add selectable AMD GPU profiles", 2026-09-28) then put both behind
  the `model == "mi25"` conditional, which is why neither applies to this host.
- **`nix-meta` pins `inferference` to `fix/restore-mi25-power-table`**, rev
  `926a45ae`. That branch adds **`ci/runner/amdgpu-soft-power-table.sh`** (94
  lines) — the applier. "Restore" means recovering a script that had only
  existed transiently during experimentation, not reverting a deletion. **Read
  this script carefully: it is the safety pattern to copy.** It gates on a
  SHA256 of the table it expects to replace and refuses to run unless the PCI
  identity matches (`EXPECTED_DEVICE=0x6860`, `EXPECTED_SUBSYSTEM_DEVICE=0x0c35`
  — MI25). A V620 equivalent would need new gating for `0x73a1`. That gating
  exists because a mismatched table can hang a card.
- **`nix/mi25-power-table.nix`** and **`nix/mi25-card0-150.pp_table`** (661
  bytes) — a working precedent for overriding a card's soft PowerPlay table
  with a binary blob, written to the `pp_table` sysfs node. `pp_table` is
  writable on the V620s too. This is the only identified route to unpinning the
  250 W cap, and it is also the most dangerous thing in this task: a malformed
  table can leave a card unusable until the blob is reverted. Understand the
  MI25 mechanism fully before considering a V620 equivalent.
- **`inferference/.scratch/projects/`** — `019-qwen3.8-27b-q4-one-v620`,
  `020-v620-fan-qwen-optimizations`, `021-q8-production-adoption`. These
  contain real measurements on this hardware. Extract any power, temperature
  and tokens-per-second figures; they may let you pick a target instead of
  guessing. `.scratch/projects/README.md` says these records are history and
  must not be rewritten.
- **`arctic-fan-watchdog.service`** — find where it is declared and how its
  curve was derived.

## What the existing measurements already say

These are recorded findings from the project history. Verify any you act on.

**The heat is not a steady-state problem.** Project 021 measured production
Q8_0 Qwen drawing **104 W with one slot and 147 W with two**, running at
**31 to 36 C**. Yet project 019 found near-cap long prompts — 7,929 tokens
against a 32,768 context — tripping the guard at **86 to 91 C** across three
ubatch settings, none completing. Project 020 observed peaks of **251 to 253 W**
during a thermally-tripped test.

So steady decode is cool and well under the cap; **prefill bursts are what
drive power to the cap and temperature to 86 C+**. That matters for every lever
here: a cap reduction would bind on prefill and barely touch decode, and an
undervolt would cut heat precisely during those bursts. Confirm this shape
before choosing a lever — and note it means a cap set anywhere above about
150 W would do nothing for normal operation.

**No V620 power-versus-throughput curve exists.** Only the MI25 was swept
(0.065 tok/s/W efficiency flattening). Measuring that curve on the V620 is
genuinely new work and would let you pick a target rather than guess.

**A cheap fix was identified a month ago and never implemented.** Project 010
ranked the options for the MI25 and put `pp_power_profile_mode = 5` (COMPUTE)
as "the single most likely fix", **ahead of** unmasking overdrive. Its actual
defect was the DPM governor failing to hold memory clock during decode, not the
power cap. No tracked `.nix` or `.sh` file anywhere sets
`pp_power_profile_mode` — it was proposed as a manual `echo` and never made
persistent. `pp_power_profile_mode` is writable on the V620s now. **Try this
before anything exotic.**

**The fan curve was never recalibrated for this hardware.** It was derived on
MI25 (`machines/hardware/arctic-fan-controller.nix`, from `RESEARCH_REPORT.md`
at commit `2e2a4f4`): junction under 45 C → PWM 180, 45-49 → 200, 50-54 → 215,
55-59 → 230, 60-64 → 245, 65 and above → 255. PWM 180 is the lowest value with
a positive tach response (2,205 RPM); PWM 255 gives 3,029 to 3,058 RPM. Project
020 flags explicitly that this curve predates the V620 installation and is
reused, not revalidated. So the blower is at full duty from 65 C upward — which
is why it was pinned at 255 during the incident, and why there is no curve
headroom above that point.

**Undervolting has never been attempted on this fleet.** `git log --all -S
"undervolt"` returns zero hits across the whole of `nix-meta`. This is open
territory, not a re-litigation.

## Decisions already made — honour these, do not re-open

- **Q8_0 K/V cache is production policy.** Project 021 records the owner's
  decision verbatim: "Let's use Q8." It was adopted for memory, not speed. Do
  not re-propose F16 or re-run that comparison without new cause.
- **Raising a power cap above stock is an owner-only safety question.** Project
  010 item 6 states this explicitly and declined to answer it. **No answer is
  recorded for the V620s.** If your plan involves raising a cap rather than
  lowering one, that is a question to put to the owner, not a tuning decision
  to make.
- **The guard threshold moved from 85 C to 80 C on 2026-10-02** and the
  justification could not be found in the records. If your reasoning depends on
  that number, ask rather than assume.

## What to work out

1. **Is `OD_VDDGFX_OFFSET` actually usable?** The empty `OD_RANGE` is the
   central unknown. Decide how to establish the legal range safely. A small
   negative offset on the **idle** card0 — not the card running the model — is
   the obvious low-risk probe. Say what you expect to happen, what you will
   measure, and how you will revert, before you write.
2. **How much does an undervolt actually buy?** Navi 21 undervolting typically
   yields a meaningful temperature drop at equal clocks. Quantify it here
   rather than citing general results: junction temperature and tokens per
   second at the same workload, offset versus no offset.
3. **What do the two freely available levers give you?**
   `power_dpm_force_performance_level` and `pp_power_profile_mode` need no
   kernel parameter and no power table. `POWER_SAVING`, or
   `profile_min_sclk`, may cut temperature substantially at some throughput
   cost. **Measure these first** — they are reversible, need no reboot, and may
   be sufficient on their own. A sufficient boring fix beats an impressive
   risky one.
4. **Is the pinned power cap worth attacking?** Lowering `power1_cap` would be
   the cleanest possible fix and the firmware does not allow it. Work out
   whether a V620 soft power table could open that range, what it would take to
   build one, and what the failure mode is if it is wrong. Then make a
   recommendation about whether it is worth the risk, given that cheaper levers
   exist.
5. **Why is card1 so much hotter than card0?** Under load card1 reached 86 C
   junction while card0 sat at 22 C, but card0 was idle, so that is not a fair
   comparison. Junction ran 11 to 12 C above edge on card1. Establish whether
   card1 cools worse than card0 under *comparable* load. If it does, this is a
   physical problem — mounting, paste, pad, duct airflow — and no voltage
   setting fixes it. Running the same model on card0 for a short measured test
   would answer it, but note that project 020 records exactly that test
   tripping the guard, so coordinate with the thermal-loop task first.
6. **Where should the setting live?** Everything here needs root and every
   control file is `root:root 644`. There is no udev rule or group that would
   let a service user write them. So the options are a kernel parameter, a
   root-run oneshot unit at boot, or a `pp_table` blob — mirroring how
   `services.inferference-mi25-power-table` does it. Pick one and justify it.
   A setting that silently fails to reapply after a reboot is worse than none.
7. **How will anyone know it is still applied?** The failure mode that matters
   is an undervolt that quietly stops applying. Propose a check — the thermal
   guard, the fan watchdog, or a small unit — that notices and says so.

## Hard limits

- **Reversibility first.** Before any write, know the exact command that undoes
  it and confirm the original value is recorded. Prefer the idle card for
  probes.
- **Never write a `pp_table` blob without the owner's explicit approval** on
  that specific blob. This is the one step that can leave a card unusable.
- **Do not raise a thermal limit to make a symptom go away.** That belongs to
  the other task and needs vendor ratings behind it.
- No change to `boot.kernelParams` takes effect without a reboot. Say so plainly
  in any plan, and remember the machine has been up six days and carries a
  generation mismatch risk described above.
- Route all version control through `gitman`, never raw `git` or `jj` for a
  mutation: `cd ~/Documents/Projects/gitman && devenv shell -- bash -c 'cd <repo> && gitman <verb>'`
- Never run `devenv` with `nix-meta` or `nix-secrets` as the working directory.
- **Activate with the explicit trunk ref.** The shared `nix-meta` working copy
  can sit behind trunk, and `.#server` has already silently built stale content
  twice:
  `sudo nixos-rebuild switch --flake 'git+file:///home/andrew/Documents/Projects/nix-meta?ref=refs/heads/main#server'`
- An activation snippet must never call `exit` — NixOS concatenates them into
  one script, and this already broke an activation on this host.
- `sudo` needs an interactive password; `sudo -n` fails. For user units:
  `export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`
- `rocm-smi` works for sysfs-backed reads but prints
  `Fail to open libdrm_amdgpu.so` and reports `Device Name: N/A`; it lacks
  `libdrm_amdgpu.so`. It has `--setperflevel`, `--setpoweroverdrive`,
  `--setsrange`, `--setslevel`, `--setvc`, but **no** `--setvoltage`.
- Simplified Technical English. No AI attribution.
- Record the work in this directory, `nix-meta/.scratch/projects/02-gpu-voltage-limiting/`.

## Reference

| Thing | Path |
|---|---|
| GPU profile | `nix-meta/profiles/gpu-compute.nix` (model conditional at line 133) |
| Machine wiring | `nix-meta/machines/server.nix` lines 92-96 |
| MI25 power table | `nix-meta/nix/mi25-power-table.nix`, `nix/mi25-card0-150.pp_table` |
| Control nodes | `/sys/class/drm/card{0,1}/device/{pp_od_clk_voltage,pp_power_profile_mode,power_dpm_force_performance_level,pp_table,pp_features,gpu_metrics}` |
| Power/temp | `/sys/class/drm/card0/device/hwmon/hwmon5/`, `card1/.../hwmon6/` |
| Blower | hwmon2, `arctic_fan`; `arctic-fan-watchdog.service` |
| Thermal guard | `inferference/ci/runner/gpu-thermal-guard.sh` |
| Router unit | `inferference/nix/nixos-module.nix` |
| Sibling task | `inferference/.scratch/projects/022-router-thermal-kill-loop/KICKOFF.md` |

Kernel 6.18.38, NixOS 26.11.20260705.d407951, generation 134. amdgpu sysfs
documentation: `https://docs.kernel.org/gpu/amdgpu/thermal.html`.

## First action

The router is stopped, so both cards are idle and you cannot reproduce the heat
without restarting it. Decide with the owner how to get a load for measurement
— restart the router, or run a controlled benchmark from the `inferference`
bench harness — and say which you recommend and why. Measure the baseline
before changing anything.

## Deliverable

A short report: what the hardware actually permits, what each lever buys in
measured temperature and throughput, a recommendation with its risk, and — once
approved — the change, verified, landed, and surviving a reboot. State plainly
whatever you could not determine.
