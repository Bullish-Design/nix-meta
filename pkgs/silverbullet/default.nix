{
  lib,
  git,
  fetchFromGitHub,
  rustPlatform,
  buildNpmPackage,
  replaceVars,
}:
let
  version = "2.10.0";
  src = fetchFromGitHub {
    owner = "silverbulletmd";
    repo = "silverbullet";
    rev = version;
    hash = "sha256-tcn0NrABLnX22OWJ3PzYJ5xbTLyNH5p6JtJ6CujkpQQ=";
  };
  frontend = buildNpmPackage {
    pname = "silverbullet-frontend";
    inherit version src;
    npmDepsHash = "sha256-We3K4jZGcC5Q1WBgEOKDKhn8M83srNLP3C36WCOX5Qs=";
    # Deterministic public version: upstream's updateVersionFile (build/version.ts)
    # wants `git describe`; in the sandbox it falls back to "<version>-unknown".
    # This patch makes it write exactly "@version@" (replaceVars fills it).
    patches = [
      (replaceVars ./override-version.patch { inherit version; })
    ];
    nativeBuildInputs = [ git ];

    postBuild = ''
      npm run build:plug-compile
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r client_bundle version.json $out/
      runHook postInstall
    '';
  };
in
rustPlatform.buildRustPackage {
  pname = "silverbullet";
  inherit version src;

  # The server embeds the client bundle (rust-embed) at compile time.
  cargoHash = "sha256-M/bX9oj76kmXGkCzvBJZMeI7/4UJ+yvz84KrysyPOLA=";

  doCheck = false;

  preBuild = ''
    cp -r ${frontend}/client_bundle .
    cp ${frontend}/version.json .
  '';


  meta = with lib; {
    description = "Open-source, self-hosted, offline-capable Personal Knowledge Management (PKM) web application";
    homepage = "https://silverbullet.md";
    license = licenses.mit;
    mainProgram = "silverbullet";
  };
}
