# Card1 power saving soak

Run this from the host terminal when card1 is cool and the production router is stopped:

```bash
sudo bash /home/andrew/Documents/Projects/nix-meta/.scratch/projects/02-gpu-voltage-limiting/run-power-saving-soak.sh
```

The script uses card1 (`0000:67:00.0`) in `manual` mode with `POWER_SAVING` profile 2 and a 0 mV offset. It checks the card identity, stock PowerPlay table, active blower watchdog, stopped router, free VRAM, and a starting temperature of 30 C or less. It starts the pinned Qwen3.8 27B GGUF through the GPU lease and thermal guard. It restores `auto`, profile 0, and 0 mV when it exits.

The runner sends repeated synthetic 600-row log analysis prompts for at least 15 minutes. Each request enables thinking, preserves thinking, uses `xhigh` reasoning effort, and permits up to 6,144 output tokens. The runner accepts a cycle only if the server reports 8,192–32,000 prompt tokens, at least 1,536 completion tokens, at least 1,024 reported reasoning tokens or 4,000 reasoning characters, a final answer of at least 1,200 characters, and a normal `stop` finish. It requires at least two complete cycles. The prompts vary each cycle to keep prompt processing active.

The monitor samples both cards and the external blower every 0.25 seconds. It kills the isolated server if either card reaches 72 C or card1 GTT use rises by more than 512 MiB. A failed request, missing reasoning, timeout, thermal stop, GTT abort, or failed model placement makes the run fail. A 15-minute target can take longer because a request that starts before the deadline runs to completion.

The script prints the artifact directory under `/mnt/shared/ai/models/qwen3.8-27b-gguf/artifacts/`. Read `summary.json` for the final `passed` value and `telemetry.jsonl` for the temperature, power, clock, voltage, and fan trace. Each cycle has saved request and response JSON. Check that the root script prints `Card1 controls restored: auto, profile 0, 0 mV.` before starting another run.
