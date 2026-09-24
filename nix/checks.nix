# Flake checks for one system; `nix flake check` builds them all.
#   vestal      the package
#   cli         smoke test of the built CLI, plus the app bundle on darwin
#   info-plist  Vestal.app's Info.plist parses and has the keys macOS reads
#   hm-module   the Home Manager module, against stub Home Manager options
#   tests       (Linux) the VestalCoreTests suite under nixpkgs' Swift
{
  pkgs,
  self,
  nixpkgs,
}:

let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux system;
  vestal = self.packages.${system}.vestal;
in
{
  inherit vestal;

  cli =
    pkgs.runCommand "vestal-cli"
      {
        nativeBuildInputs = [
          vestal
          pkgs.jq
        ]
        ++ lib.optionals isDarwin [ pkgs.python3 ];
      }
      (
        ''
          vestal version | tee version
          # The version from BuildInfo and a stamped commit, not "dev".
          grep -Eq '^vestal ${lib.escapeRegex vestal.version} \([^)]+\)$' version
          if grep -qF '(dev)' version; then
            echo "BuildInfo.commit was not stamped" >&2
            exit 1
          fi
          vestal help > /dev/null
          vestal check-config ${../examples/full.json}
          vestal print-config ${../examples/full.json} | jq -e 'type == "object"' > /dev/null
        ''
        + lib.optionalString isDarwin ''
          app=${vestal}/Applications/Vestal.app
          test -x "$app/Contents/MacOS/vestal"
          python3 ${./check-info-plist.py} "$app/Contents/Info.plist" ${vestal.version}
          # bin/vestal execs the bundle by its absolute path (see package.nix).
          test ! -L ${vestal}/bin/vestal
          grep -qF "$app/Contents/MacOS/vestal" ${vestal}/bin/vestal
        ''
        + ''
          touch $out
        ''
      );

  info-plist = pkgs.runCommand "vestal-info-plist" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 ${./check-info-plist.py} ${vestal.infoPlist} ${vestal.version}
    touch $out
  '';

  hm-module = import ./tests/hm-module.nix { inherit pkgs self nixpkgs; };
}
// lib.optionalAttrs isLinux {
  # `swift test`, as far as nixpkgs' Linux Swift allows: tests are listed by
  # a generated entry point (nix/gen-linuxmain.py) instead of discovered.
  tests = vestal.overrideAttrs (old: {
    pname = "vestal-tests";
    # The tests also read examples/full.json and docs/CONFIG.md.
    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../Package.swift
        ../Sources
        ../Tests
        ../examples
        ../docs/CONFIG.md
      ];
    };
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.python3 ];
    buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.swiftPackages.XCTest ];
    # Every target, the tests included.
    swiftpmFlags = [ "--build-tests" ];
    postPatch = old.postPatch + ''
      python3 ${./gen-linuxmain.py} Tests
    '';
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      # nixpkgs' corelibs Foundation reads time zones only from
      # /usr/share/zoneinfo/, which the build sandbox lacks, so
      # TimeZone(identifier:) returns nil and the date tests crash. Run them
      # against a copy of libFoundation whose zoneinfo path (a C string in
      # the library) is a relative path of the same length to nixpkgs' tzdata.
      foundation=${pkgs.swiftPackages.Foundation}/lib/swift/linux/libFoundation.so
      if [[ ! -d /usr/share/zoneinfo ]] && grep -qF /usr/share/zoneinfo/ "$foundation"; then
        mkdir tzfix
        LC_ALL=C sed 's|/usr/share/zoneinfo/|.//////////zoneinfo/|g' "$foundation" > tzfix/libFoundation.so
        if [[ $(stat -c %s "$foundation") != $(stat -c %s tzfix/libFoundation.so) ]]; then
          echo "patched libFoundation.so changed size" >&2
          exit 1
        fi
        ln -s ${pkgs.tzdata}/share/zoneinfo zoneinfo
        export LD_LIBRARY_PATH="$PWD/tzfix''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      fi
      "$(swiftpmBinPath)"/*PackageTests.xctest
      runHook postCheck
    '';
    installPhase = ''
      touch $out
    '';
  });
}
