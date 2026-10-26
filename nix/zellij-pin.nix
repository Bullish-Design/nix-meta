# Owned fleet Zellij pin.
#
# Version: 0.45.1 (release tag v0.45.1, commit efd8fd5a89a20c07a111d248ad7fce53848d2c18)
# Source:  the nixpkgs package set that the caller passes. profiles/agent.nix
#          passes `pi-nixpkgs`, which flake.lock pins on its own. That revision
#          builds Zellij 0.45.1 with the upstream nixpkgs recipe, and
#          cache.nixos.org holds the binary.
# Reason:  pyllij needs Zellij 0.45.0 or newer, and its tests run 0.45.1.
#          The host ran 0.44.3 from nixpkgs-unstable.
# Held:    the unreleased upstream commit 6cccad122e7bebd3dd79a3d3f19896921b669bbc
#          waits for the 0.46.0 release. It breaks background render subscriptions.
# Replace: with the 0.46.0 release when it ships. Then change `expected` below.
#
# The assertion fails the evaluation when a `pi-nixpkgs` bump moves Zellij to
# another version. A bump of the Pi pin then never changes the fleet Zellij
# without a decision. The 0.45.1 source has no `window` feature and no
# `zellij-window` binary, so the package needs no feature override.
{ lib, nixpkgs }:

let
  expected = "0.45.1";
  zellij = nixpkgs.zellij;
in
assert lib.assertMsg (zellij.version == expected)
  "nix/zellij-pin.nix: expected Zellij ${expected}, got ${zellij.version}. Decide before you bump pi-nixpkgs.";
zellij
