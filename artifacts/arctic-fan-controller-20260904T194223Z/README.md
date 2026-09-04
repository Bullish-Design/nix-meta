# ARCTIC Fan Controller evidence

This UTC artifact set was created on 2026-09-04 for the `server` configuration.

It contains static evaluation, pinned-environment build output, generated-unit
inspection, live read-only snapshots, and the safety failure that stopped live
testing. The prior `20260904T1820Z` directory contains the initial activation,
binding, channel, GPU sensor, and CoolerControl evidence.

The current live snapshot found `pwm1=150`; therefore no PWM write, daemon-stop
test, response test, reboot, or GPU load was performed in this run.

## Artifact index

Current run:

- [exact dry build](exact-dry-build.log)
- [pinned dry build](pinned-environment-dry-build-verified.log)
- [kernel version](kernel-mod-dir-version.txt)
- [kernel patches](kernel-patches.json)
- [external module packages](extra-module-packages.json)
- [kernel derivation](kernel-derivation.json)
- [flake metadata](flake-metadata.json)
- [live baseline and safety result](live-baseline-and-safety.log)
- [safe-high barrier result](safety-barrier-before-live.log)
- [Nix parse result](nix-parse.log)
- [final module inspection](final-module-inspection.log)
- [ARCTIC module store info](arctic-module-path-info.json)
- [final closure ARCTIC references](final-closure-arctic-references.log)
- [final closure references](final-requisites-arctic-references.log)
- [generated service inspection](generated-service-inspection.log)
- [generated watchdog script](generated-watchdog-script.log)
- [safe-high static scan](safety-static-scan.log)
- [toplevel path](toplevel-final-static.txt)
- [toplevel path after watchdog](toplevel-after-watchdog.txt)
- [toplevel derivation](toplevel-derivation.json)
- [toplevel store info](toplevel-after-watchdog-info.json)
- [diff check](diff-check.log)
- [pinned build before final signal fix](pinned-environment-dry-build-final-static.log)
- [pinned build after watchdog addition](pinned-environment-dry-build-after-watchdog.log)
- [initial pinned build](pinned-environment-dry-build.log)
- [initial exact command result](exact-dry-build.log)

Prior run:

- [automatic-load evidence](../arctic-fan-controller-20260904T1820Z/after-automatic-load.log)
- [controller inspection](../arctic-fan-controller-20260904T1820Z/sensor-and-controller-inspection.log)
- [CoolerControl API probes](../arctic-fan-controller-20260904T1820Z/coolercontrol-api-probes.log)
- [CoolerControl authentication discovery](../arctic-fan-controller-20260904T1820Z/coolercontrol-auth-discovery.log)
- [CoolerControl endpoint discovery](../arctic-fan-controller-20260904T1820Z/coolercontrol-endpoint-discovery.log)
- [failed activation](../arctic-fan-controller-20260904T1820Z/live-after-failed-activation.log)
- [pre-activation snapshot](../arctic-fan-controller-20260904T1820Z/live-before-activation.log)
- [manual module insertion](../arctic-fan-controller-20260904T1820Z/after-manual-insmod.log)
- [module-load diagnostics](../arctic-fan-controller-20260904T1820Z/module-load-diagnostics.log)
- [module path diagnostics](../arctic-fan-controller-20260904T1820Z/module-path-diagnostics.log)
- [initial dry build](../arctic-fan-controller-20260904T1820Z/dry-build.log)
