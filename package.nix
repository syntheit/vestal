# The vestal package, built with SwiftPM (nixpkgs' `swiftpm` setup hook runs
# `swift build -c release`). flake.nix calls this with callPackage.
#
# darwin: $out/Applications/Vestal.app, plus $out/bin/vestal for the CLI.
# Linux: $out/bin/vestal, the CLI and a headless `vestal daemon` (sources,
# socket, reload, stats), and the GTK 4 UI (VestalLinux; for now reached
# through `vestal render-file`). Its wrapper puts wpctl (WirePlumber) and
# playerctl on PATH, after the caller's own, for the volume and media
# providers. The UI's fonts (Inter, JetBrains Mono, Phosphor) are installed
# in $out/share/vestal/{fonts,icons}, where the binary looks for them.
{
  lib,
  stdenv,
  swift,
  swiftpm,
  swiftPackages,
  makeBinaryWrapper,
  writeText,
  callPackage,
  pkg-config,
  inter,
  jetbrains-mono,
  # Linux runtime tools: `wpctl get-volume` and `playerctl`.
  wireplumber,
  playerctl,
  # Linux: the time zone data the patched Foundation falls back to.
  tzdata,
  patchelf,
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

  # The Linux UI's libraries as one pkg-config module. Its icon fonts are
  # vendored in Resources/icons (Phosphor, see the README there).
  gtkPkgConfig = callPackage ./nix/gtk-pkgconfig.nix { };

  # Linux: swift-corelibs-foundation reads time zones only from its
  # compile-time TZDIR, /usr/share/zoneinfo/, which NixOS doesn't have: there
  # every TimeZone(identifier:) is nil and TimeZone.current is GMT. This build
  # picks the directory at run time ($TZDIR, /usr/share/zoneinfo, NixOS's
  # /etc/zoneinfo, then this tzdata) and names the local zone from the
  # /etc/localtime link wherever it points. vestal runs against it (postFixup).
  foundation = swiftPackages.Foundation.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./nix/foundation-tzdir.patch ];
    postPatch = (old.postPatch or "") + ''
      substituteInPlace CoreFoundation/NumberDate.subproj/CFTimeZone.c \
        --replace-fail '@tzdir@' '${tzdata}/share/zoneinfo/'
    '';
  });
  stockFoundationLib = "${swiftPackages.Foundation}/lib/swift/linux";
  foundationLib = "${foundation}/lib/swift/linux";

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
      ./Resources/icons/Phosphor.ttf
      ./Resources/icons/Phosphor-Fill.ttf
      ./Resources/icons/LICENSE
    ];
  };

  nativeBuildInputs = [
    swift
    swiftpm
    makeBinaryWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    pkg-config
    patchelf
  ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ gtkPkgConfig ];

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
      # --suffix: a wpctl or playerctl the user has on PATH comes first.
      ''
        install -Dm755 "$(swiftpmBinPath)/vestal" "$out/libexec/vestal/vestal"
        mkdir -p "$out/share/vestal/fonts" "$out/share/vestal/icons"
        ln -s ${inter}/share/fonts "$out/share/vestal/fonts/inter"
        ln -s ${jetbrains-mono}/share/fonts/truetype "$out/share/vestal/fonts/jetbrains-mono"
        install -m644 Resources/icons/Phosphor.ttf Resources/icons/Phosphor-Fill.ttf Resources/icons/LICENSE \
          "$out/share/vestal/icons/"
        makeBinaryWrapper "$out/libexec/vestal/vestal" "$out/bin/vestal" \
          --suffix PATH : ${
            lib.makeBinPath [
              wireplumber
              playerctl
            ]
          }
      ''
  )
  + ''
    runHook postInstall
  '';

  # Linux: load Foundation from the time-zone-patched build (same sources,
  # same ABI) instead of nixpkgs' one. After the fixup phase, which shrinks
  # the RUNPATH; fails if the stock entry isn't there to replace.
  postFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
    bin="$out/libexec/vestal/vestal"
    stock=${stockFoundationLib}
    patched=${foundationLib}
    rpath=$(patchelf --print-rpath "$bin")
    case ":$rpath:" in
      *":$stock:"*) ;;
      *) echo "vestal: $bin's RUNPATH has no $stock: $rpath" >&2; exit 1 ;;
    esac
    patchelf --set-rpath "''${rpath//"$stock"/"$patched"}" "$bin"
  '';

  passthru = {
    inherit infoPlist;
    # Linux: the Foundation vestal runs against (see `foundation` above).
    foundation = if stdenv.hostPlatform.isLinux then foundation else null;
    # Whether `vestal daemon` runs on this platform; the Home Manager module
    # only installs a login service when it does. On Linux it runs headless
    # until the UI exists.
    supportsDaemon = true;
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
