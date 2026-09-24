# The vestal package, built with SwiftPM (nixpkgs' `swiftpm` setup hook runs
# `swift build -c release`). flake.nix calls this with callPackage.
#
# darwin: $out/Applications/Vestal.app, plus $out/bin/vestal for the CLI.
# Linux: $out/bin/vestal only. It runs the CLI commands; the Linux UI does not
# exist yet.
{
  lib,
  stdenv,
  swift,
  swiftpm,
  swiftPackages,
  makeBinaryWrapper,
  writeText,
  # Short commit hash shown in the info popup (BuildInfo.commit).
  commit ? "dev",
}:

let
  # The version lives in one place: BuildInfo.version.
  version =
    let
      m = builtins.match ''.*static let version[^"]*"([^"]+)".*'' (
        builtins.readFile ./Sources/VestalCore/BuildInfo.swift
      );
    in
    if m == null then throw "package.nix: no BuildInfo.version found" else builtins.head m;

  # Contents/Info.plist of Vestal.app. Generated rather than templated, so it
  # is well-formed by construction; the flake's `info-plist` check parses it.
  infoPlist = writeText "Info.plist" (
    lib.generators.toPlist { escape = true; } {
      CFBundleDevelopmentRegion = "en";
      CFBundleDisplayName = "Vestal";
      CFBundleExecutable = "vestal";
      CFBundleIdentifier = "io.matv.vestal";
      CFBundleInfoDictionaryVersion = "6.0";
      CFBundleName = "Vestal";
      CFBundlePackageType = "APPL";
      CFBundleShortVersionString = version;
      CFBundleVersion = version;
      LSMinimumSystemVersion = "14.0";
      # No Dock icon or menu bar; the app also sets the accessory policy itself.
      LSUIElement = true;
      NSHighResolutionCapable = true;
      NSPrincipalClass = "NSApplication";
      # Shown by macOS the first time vestal asks for calendar access (agenda).
      NSCalendarsUsageDescription = "Vestal shows your upcoming events on the dashboard.";
      NSCalendarsFullAccessUsageDescription = "Vestal shows your upcoming events on the dashboard.";
      # Shown the first time vestal asks the media player for the current track.
      NSAppleEventsUsageDescription = "Vestal shows what your media player is playing and can pause it.";
    }
  );
in
stdenv.mkDerivation {
  pname = "vestal";
  inherit version;

  # Only what SwiftPM reads, so editing docs doesn't trigger a rebuild.
  # Package.swift declares the test target, and SwiftPM refuses the package
  # without its directory even when it builds only `vestal`.
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
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [ makeBinaryWrapper ];

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

  # SwiftPM writes caches under $HOME. Without a sandbox, HOME is
  # /homeless-shelter, which must not exist (Nix refuses to build once it
  # does) and cannot be created on macOS.
  preConfigure = ''
    export HOME="$TMPDIR"
  '';

  # On darwin, bin/vestal is a compiled wrapper that execs the bundle's
  # executable by its absolute path, not a symlink to it. macOS finds a
  # process's bundle (Bundle.main, and so the Info.plist and the TCC identity
  # for calendar and Apple Events access) from the path it was exec'd with,
  # which for a symlink on PATH is the symlink's own path outside the bundle.
  # The wrapper also passes the bundle path as argv[0], so relaunching self
  # from argv[0] starts the bundle too.
  installPhase = ''
    runHook preInstall
  ''
  + (
    if stdenv.hostPlatform.isDarwin then
      ''
        app="$out/Applications/Vestal.app"
        install -Dm755 "$(swiftpmBinPath)/vestal" "$app/Contents/MacOS/vestal"
        install -Dm644 ${infoPlist} "$app/Contents/Info.plist"
        printf 'APPL????' > "$app/Contents/PkgInfo"
        makeBinaryWrapper "$app/Contents/MacOS/vestal" "$out/bin/vestal"
      ''
    else
      ''
        install -Dm755 "$(swiftpmBinPath)/vestal" "$out/bin/vestal"
      ''
  )
  + ''
    runHook postInstall
  '';

  passthru = {
    inherit infoPlist;
    # Whether `vestal daemon` runs on this platform; the Home Manager module
    # only installs a login service when it does. Linux gets one with its UI.
    supportsDaemon = stdenv.hostPlatform.isDarwin;
  };

  meta = {
    description = "Keypress-toggled full-screen dashboard overlay";
    homepage = "https://github.com/syntheit/vestal";
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];
    mainProgram = "vestal";
  };
}
