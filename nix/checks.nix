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
          vestal check-config ${../examples/full.json}
          vestal print-config ${../examples/full.json} | jq -e 'type == "object"' > /dev/null

          # The CLI contract the launch agent and activation rely on.
          vestal help > help
          for command in daemon toggle show hide reload status quit check-config print-config; do
            grep -qE "^  $command " help
          done
          # With no instance, hide, reload, status and quit say so and exit 1;
          # none of them starts one.
          for command in hide reload status quit; do
            rc=0
            vestal "$command" > out 2> err || rc=$?
            if [ "$rc" != 1 ] || ! grep -qxF 'vestal: not running' err; then
              echo "vestal $command with no instance: exit $rc, $(cat err)" >&2
              exit 1
            fi
          done
          rc=0
          vestal status > /dev/null 2>&1 || rc=$?
          [ "$rc" = 1 ]
          # Usage errors exit 2.
          rc=0
          vestal bogus 2> /dev/null || rc=$?
          [ "$rc" = 2 ]
          rc=0
          vestal toggle now 2> /dev/null || rc=$?
          [ "$rc" = 2 ]
        ''
        + lib.optionalString isLinux ''
          # The headless daemon (no UI on Linux yet): it takes the socket,
          # answers status with stats, keeps the visibility show and hide
          # set while saying there is no UI, reloads, refuses a second
          # instance, and quits.
          export XDG_RUNTIME_DIR="$TMPDIR/run" XDG_CONFIG_HOME="$TMPDIR/config" XDG_CACHE_HOME="$TMPDIR/cache"
          mkdir -m 700 "$XDG_RUNTIME_DIR"
          vestal daemon 2> daemon.log &
          daemon=$!
          for _ in $(seq 100); do vestal status > /dev/null 2>&1 && break; sleep 0.1; done
          vestal status | tee status
          grep -qx 'running: pid [0-9]*, hidden' status
          grep -qx '  cpu: [0-9]*%' status
          grep -q '^  memory: [0-9]*% used' status
          vestal status --json | jq -e '.stats.memory.ramPercent >= 0 and (.stats.uptime > 0)' > /dev/null
          vestal show 2> show.err
          grep -qxF 'vestal: no UI on this platform yet; the dashboard is now shown' show.err
          vestal status | grep -qx 'running: pid [0-9]*, shown'
          vestal toggle 2> /dev/null
          vestal status | grep -qx 'running: pid [0-9]*, hidden'
          vestal reload
          # Same build: a second daemon leaves the first alone and exits 0.
          vestal daemon 2> second.err
          grep -q 'already running' second.err
          vestal quit
          wait "$daemon"
          test ! -e "$XDG_RUNTIME_DIR/vestal.sock"
          grep -q 'running headless' daemon.log
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
