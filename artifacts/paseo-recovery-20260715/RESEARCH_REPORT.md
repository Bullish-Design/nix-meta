# Paseo recovery and Serve dependency fix — 2026-07-15

## Target and acceptance criteria

Restore the Paseo daemon, restore the tailnet HTTPS proxy on port 8443, and
ensure a future Paseo restart does not remove the Tailscale Serve route.

## Baseline

- `paseo.service` was in an auto-restart loop with `Failed to acquire PID lock
  due to race condition`.
- `/home/andrew/.paseo/paseo.pid` was an empty file, created at
  `2026-07-15 00:52:46 -0400`.
- `paseo-tailscale-serve.service` was failed; `tailscale serve status --json`
  contained only unrelated TCP forwards (8122 and 8123), not HTTPS 8443.

## Cause

Paseo version `0.1.106-beta.1` treats an invalid PID file as ignorable during
its first read, but does not remove it before an exclusive create. The empty
file therefore causes every start to fail with `EEXIST` and the race-condition
error. Removing the confirmed stale file allowed the service's restart policy
to start Paseo successfully.

The NixOS Serve unit was also `PartOf=paseo.service` and `Requires=paseo.service`.
An applied local workaround made Paseo `Wants=paseo-tailscale-serve.service`.
During the daemon crash loop, that repeatedly started the Serve unit and then
stopped it; its `ExecStop` removed the HTTPS 8443 route.

## Implemented fix

Commit `f416aec` in `nix-paseo` implements the final host-side design:

- a conservative pre-start helper removes only malformed regular PID-lock files
  older than a configurable grace period (30 seconds by default);
- schema-valid locks, recent malformed locks, symlinks, and non-regular paths
  are left untouched or rejected safely;
- the Serve unit has no `PartOf=`, `Requires=`, or route-removing `ExecStop=`;
- Serve waits for Tailscale readiness, applies HTTPS 8443 idempotently, and
  retries transient failures; and
- route removal is isolated in an explicit manual cleanup unit.

The `nix-meta` lock pins that commit. Its local `shellij` and
`structured-agents` inputs were also converted from recursive `path:` inputs to
commit-backed `git+file:` inputs, preventing generated deployment environments
from being copied into the Nix store during evaluation.

## Evidence

- PID-lock fixture tests, module evaluation tests, and
  `devenv shell -- nix flake check` in `nix-paseo`: passed.
- The updated `nix-paseo` input lock resolves to commit `f416aec`.
- The complete `nix-meta#server` NixOS closure built successfully as
  `/nix/store/6c25d02rkr3rn5yzd9cqvs35l9r5hnza-nixos-system-server-26.11.20260705.d407951`.
- Generated units confirm PID recovery runs before Paseo, normal Serve stops do
  not remove HTTPS 8443, and route cleanup is explicit.
- After stale-lock removal, `paseo.service` was active and logged listening on
  `127.0.0.1:6767`; a local HTTP request succeeded.

## Remaining boundary

Applying the already-built generation requires interactive local administrator
authentication. This session has no passwordless sudo, so HTTPS 8443 cannot be
revalidated until the user runs `sudo nixos-rebuild switch --flake
/home/andrew/Documents/Projects/nix-meta#server`. The old generation currently
has a healthy Paseo daemon but its pre-fix Serve unit remains failed.

## Long-term design review

The initial `b214b0f` containment change was sound but incomplete. Commit
`f416aec` implements the complete host-side mitigation while leaving the Paseo
library unchanged.

1. The upstream Paseo PID-lock defect remains present on upstream `main` as of
   2026-07-15. It opens `paseo.pid` exclusively and writes the payload afterward;
   an interruption between those operations leaves an empty file. A subsequent
   start accepts invalid JSON during the initial read but then fails permanently
   on `EEXIST`. The primary fix belongs upstream and needs an interruption/
   malformed-lock regression test:
   https://github.com/getpaseo/paseo/blob/main/packages/server/src/server/pid-lock.ts
2. Removing `Requires=` and `PartOf=` is correct because Tailscale Serve is
   persistent desired proxy configuration, not a subprocess of Paseo. systemd
   documents that both dependencies propagate stop/restart operations:
   https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
3. Tailscale documents that `serve --bg` persists across reboot and tailscaled
   restarts until explicitly disabled. The final unit therefore has no
   route-removing `ExecStop`; an explicit cleanup unit owns removal:
   https://tailscale.com/docs/reference/tailscale-cli/serve
4. Ordering after `tailscaled.service` is insufficient readiness. The observed
   `unexpected state: NoState` occurred after that service was considered
   started. Installed Tailscale 1.98.8 supports `tailscale wait`; the unit should
   wait with a finite timeout and retry on transient failure:
   https://tailscale.com/docs/reference/tailscale-cli

The implemented final shape is an independent idempotent reconciliation unit:
wait for Tailscale readiness, apply the scoped HTTPS 8443 route with `--bg`, do
not clear it during normal service stop/restart, and retry transient failures.
Disabling/removing the route is a distinct explicit reconciliation path rather
than `ExecStop`. Post-activation runtime acceptance still needs daemon restart,
tailscaled restart, reboot, and NixOS switch tests while confirming the
unrelated 8122/8123 routes remain.

### Host-side PID-lock mitigation

If upstream Paseo cannot be changed, `nix-paseo` can prepend a conservative
`paseo.service` pre-start sanitizer. It should:

- leave every schema-valid lock untouched, whether its PID is live or stale;
- leave malformed locks younger than a grace period (recommended: 30 seconds)
  untouched, avoiding a race with another process that has created but not yet
  written its lock;
- remove only a malformed regular file older than that grace period; and
- log the recovery action to the journal.

The upstream service already retries after five seconds, so a newly malformed
lock would fail safely for several starts and then self-heal after the grace
period. Tests should cover absent, valid/live, valid/stale, recent malformed,
old empty, old truncated-JSON, and non-regular paths. This mitigation can be
removed after the pinned Paseo version publishes its lock atomically or safely
recovers abandoned malformed locks.
