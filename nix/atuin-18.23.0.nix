{ inputs, lib, pkgs }:

inputs.atuin.packages.${pkgs.stdenv.hostPlatform.system}.atuin.overrideAttrs
  (old: {
    version = "18.23.0";

    # Atuin v18.23.0's upstream Nix expression adds OpenSSL's RUNPATH to the
    # client only. Cargo installs atuin-server from the same source build, and
    # that ELF has the same libssl/libcrypto dependencies, so patch it at the
    # package boundary too. Remove this when upstream patches every installed
    # binary or no longer links atuin-server dynamically against OpenSSL.
    postFixup = (old.postFixup or "") + ''
      patchelf --add-rpath "${lib.makeLibraryPath [ pkgs.openssl ]}" \
        "$out/bin/atuin-server"
    '';
  })
