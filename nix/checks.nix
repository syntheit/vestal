# Flake checks for one system; `nix flake check` builds them all.
#   vestal      the package
#   cli         smoke test of the built CLI, plus the app bundle on darwin
#   info-plist  Vestal.app's Info.plist parses and has the keys macOS reads
#   hm-module   the Home Manager module, against stub Home Manager options
#   tests       (Linux) the VestalCoreTests suite under nixpkgs' Swift
#   wayland-glue (Linux) Sources/CWaylandCapture matches wayland-scanner's output
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
          # check-config v2: zero diagnostics for the example, a pointer and
          # a suggestion for a typo, exit 3 under --strict.
          vestal check-config --json --strict ${../examples/full.json} | jq -e '.status == "ok" and .counts.warning == 0' > /dev/null
          echo '{"hotkeys": "f3"}' > typo.json
          vestal check-config --json typo.json | jq -e '.diagnostics[0].pointer == "/hotkeys" and .diagnostics[0].suggestion == "hotkey"' > /dev/null
          rc=0
          vestal check-config --strict typo.json > /dev/null || rc=$?
          [ "$rc" = 3 ]
          vestal check-config --commands ${../examples/full.json} > /dev/null
          # Every starter is a clean config on both platforms.
          for dir in ${../Resources/starters}/*/; do
            for platform in macos linux; do
              vestal check-config --json --platform $platform "$dir/config.json" | jq -e '.counts.error == 0' > /dev/null
            done
          done
          vestal init --list | grep -q '^default '
          vestal init --print --starter developer | jq -e '.hotkey == "cmd+shift+space"' > /dev/null
          vestal print-config --origins ${../examples/full.json} | grep -q '^/widgets/claude/type  *"claudeUsage"  *user$'
          # The schema is the committed one, and the docs are built in.
          vestal schema | cmp - ${../docs/vestal.schema.json}
          vestal docs agents | grep -q '^# Configuring vestal'
          rc=0
          vestal docs nosuchtopic 2> /dev/null || rc=$?
          [ "$rc" = 4 ]

          # The CLI contract the launch agent and activation rely on.
          vestal help > help
          for command in daemon toggle show hide reload status quit check-config print-config schema docs; do
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
          vestal toggle now later 2> /dev/null || rc=$?
          [ "$rc" = 2 ]
          # A view the config doesn't have is "not found"; nothing starts.
          rc=0
          vestal toggle nowhere 2> /dev/null || rc=$?
          [ "$rc" = 4 ]
        ''
        + lib.optionalString isLinux ''
          export XDG_RUNTIME_DIR="$TMPDIR/run" XDG_CONFIG_HOME="$TMPDIR/config" XDG_CACHE_HOME="$TMPDIR/cache"
          mkdir -m 700 "$XDG_RUNTIME_DIR"
          # No display in the sandbox: the GTK daemon says so and exits 1
          # (so systemd restarts it), leaving the socket free.
          rc=0
          env -u WAYLAND_DISPLAY -u DISPLAY vestal daemon 2> nodisplay.err || rc=$?
          [ "$rc" = 1 ]
          grep -q "can't start the dashboard: no display" nodisplay.err
          test ! -e "$XDG_RUNTIME_DIR/vestal.sock"
          # The headless daemon (--headless): it takes the socket, answers
          # status with stats, keeps the visibility show and hide set while
          # saying there is no UI, has no renderer for screenshots (exit 5),
          # reloads, refuses a second instance, and quits.
          vestal daemon --headless 2> daemon.log &
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
          rc=0
          vestal screenshot "$TMPDIR/shot.png" 2> /dev/null || rc=$?
          [ "$rc" = 5 ]
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
  # The protocol glue vendored in Sources/CWaylandCapture is wayland-scanner's
  # output for the XML next to it (protocols/README).
  wayland-glue = pkgs.runCommand "vestal-wayland-glue" { nativeBuildInputs = [ pkgs.wayland-scanner ]; } ''
    dir=${../Sources/CWaylandCapture}
    for x in $dir/protocols/*.xml; do
      n=$(basename $x .xml)
      wayland-scanner client-header $x header.h
      wayland-scanner private-code $x code.c
      cmp header.h $dir/$n-client-protocol.h
      cmp code.c $dir/$n-protocol.c
    done
    touch $out
  '';

  # `swift test`, as far as nixpkgs' Linux Swift allows: tests are listed by
  # a generated entry point (nix/gen-linuxmain.py) instead of discovered.
  tests = vestal.overrideAttrs (old: {
    pname = "vestal-tests";
    # The tests also read examples/full.json, docs/CONFIG.md, the committed
    # schema, the Markdown embedded as `vestal docs`, the icon metadata and the samples.
    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../Package.swift
        ../Sources
        ../Tests
        ../examples
        ../docs/CONFIG.md
        ../docs/vestal.schema.json
        ../docs/reference
        ../docs/guide
        ../AGENTS.md
        ../Resources/icons
        ../Resources/fonts
        ../Resources/samples
        ../Resources/starters
        ../Resources/shaders
      ];
    };
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.python3 ];
    # A comma-decimal locale, so the test that numbers stay American under
    # LC_NUMERIC=es_AR (mantle's) runs rather than skips.
    LOCALE_ARCHIVE = "${
      pkgs.glibcLocales.override {
        allLocales = false;
        locales = [ "es_AR.UTF-8/UTF-8" ];
      }
    }/lib/locale/locale-archive";
    buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.swiftPackages.XCTest ];
    # Every target, the tests included.
    swiftpmFlags = [ "--build-tests" ];
    postPatch = old.postPatch + ''
      python3 ${./gen-linuxmain.py} Tests
    '';
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      # Against the Foundation the package runs with (package.nix), which
      # finds time zones without /usr/share/zoneinfo: nixpkgs' own reads only
      # that directory, so TimeZone(identifier:) would be nil here. The
      # sandbox has no zoneinfo directory at all, so this also tests its
      # fallback to the tzdata it was built with.
      export LD_LIBRARY_PATH="${vestal.foundation}/lib/swift/linux''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      "$(swiftpmBinPath)"/*PackageTests.xctest
      runHook postCheck
    '';
    installPhase = ''
      touch $out
    '';
    # Nothing installed, so no RUNPATH to point at that Foundation.
    postFixup = "";
  });
}
