# The vestal executable, built with SwiftPM (nixpkgs' `swiftpm` setup hook
# runs `swift build -c release`). flake.nix calls this with callPackage.
{
  lib,
  stdenv,
  swift,
  swiftpm,
  swiftPackages,
  # Short commit hash shown in the info popup (BuildInfo.commit).
  commit ? "dev",
}:

stdenv.mkDerivation {
  pname = "vestal";
  version = "0.1.0";

  # Only what SwiftPM reads, so editing docs doesn't trigger a rebuild.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Package.swift
      ./Sources
      ./Tests
    ];
  };

  nativeBuildInputs = [
    swift
    swiftpm
  ];

  # SwiftPM compiles and runs Package.swift, which on Linux needs libdispatch
  # on the library path (nixpkgs' own swift-format does the same).
  env.LD_LIBRARY_PATH = lib.optionalString stdenv.hostPlatform.isLinux (
    lib.makeLibraryPath [ swiftPackages.Dispatch ]
  );

  # The executable only; the test target is not built.
  swiftpmFlags = [
    "--product"
    "vestal"
  ];

  # Stamp the commit into BuildInfo. The full literal assignment is replaced
  # so the word "dev" anywhere else in the file (comments etc.) is untouched.
  postPatch = ''
    substituteInPlace Sources/VestalCore/BuildInfo.swift \
      --replace-fail 'let commit  = "dev"' 'let commit  = "${commit}"'
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 "$(swiftpmBinPath)/vestal" "$out/bin/vestal"
    runHook postInstall
  '';

  meta = {
    description = "Native macOS dashboard — press a key, see everything at a glance";
    platforms = lib.platforms.darwin;
    mainProgram = "vestal";
  };
}
