{
  lib,
  stdenv,
  kernel,
  driverSource,
}:

stdenv.mkDerivation {
  pname = "arctic-fan-controller-${kernel.modDirVersion}";
  version = "kernel-module";

  # The native driver is currently present in nixpkgs' testing kernel source.
  # Only the driver file is copied into this small external-module build tree;
  # the module itself is compiled against the selected host kernel below.
  src = driverSource;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  unpackPhase = ''
    runHook preUnpack
    cp "$src/drivers/hwmon/arctic_fan_controller.c" arctic_fan_controller.c
    cp ${./Makefile} Makefile
    runHook postUnpack
  '';

  postPatch = ''
    # The controller has no GET_REPORT operation. Its driver-side PWM cache
    # therefore starts at zero unless initialized explicitly. Fill the cache
    # with 255 at probe and after resume so the first complete protocol report
    # is fail-high. The NixOS safety service still writes/verifies every
    # channel before normal fan control is allowed to lower any value.
    substituteInPlace arctic_fan_controller.c \
      --replace-fail \
        'memset(priv->pwm_duty, 0, sizeof(priv->pwm_duty));' \
        'memset(priv->pwm_duty, 255, sizeof(priv->pwm_duty));'
    substituteInPlace arctic_fan_controller.c \
      --replace-fail \
        'priv->hdev = hdev;' \
        'priv->hdev = hdev; memset(priv->pwm_duty, 255, sizeof(priv->pwm_duty));'
  '';

  buildPhase = ''
    make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build M=$PWD modules
  '';

  installPhase = ''
    install -D arctic_fan_controller.ko \
      $out/lib/modules/${kernel.modDirVersion}/updates/arctic_fan_controller.ko
  '';

  dontFixup = true;

  meta = {
    description = "Native ARCTIC Fan Controller hwmon module for the selected kernel";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
}
