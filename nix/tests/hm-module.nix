# Evaluates homeManagerModules.default with lib.evalModules against stub
# declarations of the Home Manager options it sets (this flake has no
# home-manager input), with a darwin and a Linux pkgs, and checks the result.
# The signing activation script also runs here, against a fake Vestal.app,
# with codesign and launchctl replaced by stubs.
{
  pkgs,
  self,
  nixpkgs,
}:

let
  inherit (pkgs) lib;

  # Home Manager's lib extension: the DAG helpers for home.activation.
  hmLib = lib.extend (
    final: prev: {
      hm.dag = {
        entryAnywhere = data: {
          inherit data;
          before = [ ];
          after = [ ];
        };
        entryAfter = after: data: {
          inherit data after;
          before = [ ];
        };
        entryBefore = before: data: {
          inherit data before;
          after = [ ];
        };
        entryBetween = before: after: data: { inherit data before after; };
      };
    }
  );

  # The launchd.plist keys the module sets, typed as in Home Manager's
  # modules/launchd/launchd.nix. Unknown keys are errors there too.
  launchdConfig =
    { lib, ... }:
    let
      inherit (lib) mkOption types;
      nullOr =
        t:
        mkOption {
          type = types.nullOr t;
          default = null;
        };
    in
    {
      options = {
        Label = mkOption { type = types.str; };
        ProgramArguments = nullOr (types.listOf types.str);
        EnvironmentVariables = nullOr (types.attrsOf types.str);
        KeepAlive = nullOr (
          types.either types.bool (
            types.submodule {
              options = {
                SuccessfulExit = nullOr types.bool;
                Crashed = nullOr types.bool;
              };
            }
          )
        );
        RunAtLoad = nullOr types.bool;
        ProcessType = nullOr (
          types.enum [
            "Background"
            "Standard"
            "Adaptive"
            "Interactive"
          ]
        );
        StandardOutPath = nullOr types.path;
        StandardErrorPath = nullOr types.path;
      };
    };

  stubs =
    { config, lib, ... }:
    let
      inherit (lib) mkOption types;
      home = config.home.homeDirectory;
      # systemd.user.services.<name>.<Section>.<Key>, as in Home Manager.
      primitive = types.oneOf [
        types.bool
        types.int
        types.str
        types.path
      ];
    in
    {
      options = {
        assertions = mkOption {
          type = types.listOf types.attrs;
          default = [ ];
        };
        warnings = mkOption {
          type = types.listOf types.str;
          default = [ ];
        };
        home.username = mkOption { type = types.str; };
        home.homeDirectory = mkOption { type = types.path; };
        home.profileDirectory = mkOption {
          type = types.str;
          default = "${home}/.nix-profile";
        };
        home.packages = mkOption {
          type = types.listOf types.package;
          default = [ ];
        };
        home.activation = mkOption {
          type = types.attrsOf (
            types.submodule {
              options = {
                data = mkOption { type = types.str; };
                before = mkOption { type = types.listOf types.str; };
                after = mkOption { type = types.listOf types.str; };
              };
            }
          );
          default = { };
        };
        xdg.configHome = mkOption {
          type = types.str;
          default = "${home}/.config";
        };
        xdg.stateHome = mkOption {
          type = types.str;
          default = "${home}/.local/state";
        };
        xdg.configFile = mkOption {
          type = types.attrsOf (types.submodule { options.source = mkOption { type = types.path; }; });
          default = { };
        };
        launchd.agents = mkOption {
          type = types.attrsOf (
            types.submodule (
              { name, ... }:
              {
                options = {
                  enable = mkOption {
                    type = types.bool;
                    default = false;
                  };
                  config = mkOption {
                    type = types.submodule launchdConfig;
                    default = { };
                  };
                };
                config.config.Label = lib.mkDefault "org.nix-community.home.${name}";
              }
            )
          );
          default = { };
        };
        systemd.user.services = mkOption {
          type = types.attrsOf (
            types.attrsOf (types.attrsOf (types.either primitive (types.listOf primitive)))
          );
          default = { };
        };
      };
    };

  home = "/home-dir/jane";
  identity = "Apple Development: Jane Doe (ABCDE12345)";
  settings = {
    hotkey = "f3";
    platform.linux.hotkey = "home";
  };

  # Stand-in packages that build on any system: a Vestal.app whose executable
  # is a script naming the build, and a Linux-style daemon flag. Two builds,
  # to test updates.
  fakeBuild =
    name:
    pkgs.runCommand name
      {
        passthru.supportsDaemon = true;
        meta.mainProgram = "vestal";
      }
      ''
        app=$out/Applications/Vestal.app/Contents
        mkdir -p $app/MacOS $out/bin
        printf '#!/bin/sh\necho ${name} "$@"\n' > $app/MacOS/vestal
        chmod +x $app/MacOS/vestal
        echo '<plist version="1.0"><dict/></plist>' > $app/Info.plist
        ln -s $app/MacOS/vestal $out/bin/vestal
      '';
  fake = fakeBuild "vestal-fake";
  fakeB = fakeBuild "vestal-fake-b";

  evaluate =
    system: vestal:
    (hmLib.evalModules {
      modules = [
        stubs
        self.homeManagerModules.default
        {
          _module.args.pkgs = nixpkgs.legacyPackages.${system};
          home.username = "jane";
          home.homeDirectory = home;
          programs.vestal = {
            enable = true;
          }
          // vestal;
        }
      ];
    }).config;

  darwin = evaluate "aarch64-darwin" { };
  darwinSigned = evaluate "aarch64-darwin" {
    inherit settings;
    signingIdentity = identity;
    package = fake;
  };
  darwinSignedNoAgent = evaluate "aarch64-darwin" {
    signingIdentity = identity;
    launchAtLogin = false;
  };
  linux = evaluate "x86_64-linux" { signingIdentity = identity; };
  linuxDaemon = evaluate "x86_64-linux" { package = fake; };
  badSettings = evaluate "x86_64-linux" { settings = [ 1 ]; };

  darwinApp = "${self.packages.aarch64-darwin.vestal}/Applications/Vestal.app";
  agent = c: c.launchd.agents.vestal.config;
  plist = c: lib.generators.toPlist { escape = true; } (agent c);
  passes = c: lib.all (a: a.assertion) c.assertions;
  names = c: map (p: p.name) c.home.packages;

  expectations = {
    "darwin: no config file for empty settings" = !(darwin.xdg.configFile ? "vestal/config.json");
    "darwin: the package on PATH" = names darwin == [ self.packages.aarch64-darwin.vestal.name ];
    "darwin: agent runs the store bundle hidden" =
      (agent darwin).ProgramArguments == [
        "${darwinApp}/Contents/MacOS/vestal"
        "daemon"
      ];
    "darwin: agent keep-alive and load" =
      (agent darwin).KeepAlive.SuccessfulExit == false && (agent darwin).RunAtLoad;
    "darwin: agent label" = (agent darwin).Label == "org.nix-community.home.vestal";
    "darwin: agent PATH" =
      (agent darwin).EnvironmentVariables.PATH == lib.concatStringsSep ":" [
        "${home}/.nix-profile/bin"
        "/etc/profiles/per-user/jane/bin"
        "/run/current-system/sw/bin"
        "/nix/var/nix/profiles/default/bin"
        "/opt/homebrew/bin"
        "/usr/local/bin"
        "/usr/bin"
        "/bin"
        "/usr/sbin"
        "/sbin"
      ];
    "darwin: agent config dir" =
      (agent darwin).EnvironmentVariables.XDG_CONFIG_HOME == "${home}/.config";
    "darwin: no systemd service" = darwin.systemd.user.services == { };
    "darwin: reload after linking" =
      lib.elem "linkGeneration" darwin.home.activation.vestalReload.after
      && lib.hasInfix "/bin/vestal reload" darwin.home.activation.vestalReload.data;
    "darwin: no signing without an identity" = !(darwin.home.activation ? vestalSignApp);
    "darwin: removes a signed copy once the identity is unset" =
      lib.elem "setupLaunchAgents" darwin.home.activation.vestalRemoveSignedApp.after;
    "darwin: assertions pass" = passes darwin;

    "signed: settings written with version 1" =
      builtins.fromJSON darwinSigned.xdg.configFile."vestal/config.json".source.value
      == settings // { version = 1; };
    "signed: agent runs the signed copy" =
      builtins.head (agent darwinSigned).ProgramArguments
      == "${home}/Applications/Vestal.app/Contents/MacOS/vestal";
    "signed: sign step between writeBoundary and setupLaunchAgents" =
      darwinSigned.home.activation.vestalSignApp.after == [ "writeBoundary" ]
      && darwinSigned.home.activation.vestalSignApp.before == [ "setupLaunchAgents" ];
    "signed: PATH runs the signed copy" = names darwinSigned == [ "vestal" ];
    "signed: no removal step" = !(darwinSigned.home.activation ? vestalRemoveSignedApp);
    "signed, no agent: nothing to restart" =
      !(darwinSignedNoAgent.launchd.agents ? vestal)
      && lib.hasInfix "local agent=''\n" darwinSignedNoAgent.home.activation.vestalSignApp.data;

    "linux: no service until the package has a daemon" = linux.systemd.user.services == { };
    "linux: no launchd agent" = linux.launchd.agents == { };
    "linux: signing identity ignored" =
      !(linux.home.activation ? vestalSignApp) && !(linux.home.activation ? vestalRemoveSignedApp);
    "linux: the package on PATH" = names linux == [ self.packages.x86_64-linux.vestal.name ];
    "linux: reload on activation" = linux.home.activation ? vestalReload;
    "linux daemon: service" =
      linuxDaemon.systemd.user.services.vestal.Service.ExecStart == "${fake}/bin/vestal daemon"
      && linuxDaemon.systemd.user.services.vestal.Install.WantedBy == [ "graphical-session.target" ];
    "settings must be an object" = !(passes badSettings);
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) expectations);

  # Rendered outputs, kept in $out for inspection. Context is dropped: the
  # darwin ones name store paths that can't be built here.
  text = name: s: pkgs.writeText name (builtins.unsafeDiscardStringContext s);
  rendered = {
    "darwin-agent.plist" = plist darwin;
    "signed-agent.plist" = plist darwinSigned;
    "sign.sh" = darwinSigned.home.activation.vestalSignApp.data;
    "sign-no-agent.sh" = darwinSignedNoAgent.home.activation.vestalSignApp.data;
    "unsign.sh" = darwin.home.activation.vestalRemoveSignedApp.data;
    "reload.sh" = darwin.home.activation.vestalReload.data;
    "linux-service.json" = builtins.toJSON linuxDaemon.systemd.user.services.vestal;
  };
in
assert lib.assertMsg (failed == [ ]) "hm-module: failed: ${lib.concatStringsSep "; " failed}";
pkgs.runCommand "vestal-hm-module"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    mkdir -p $out
    ${lib.concatStrings (
      lib.mapAttrsToList (name: s: ''
        cp ${text name s} $out/${name}
      '') rendered
    )}
    for f in $out/*.plist; do
      python3 -c 'import plistlib, sys; plistlib.load(open(sys.argv[1], "rb"))' "$f"
    done
    for f in $out/*.sh; do
      bash -n "$f"
    done

    # Run the signing steps against the fake builds, as activation does.
    stubs=$PWD/stubs home=$PWD/home log=$PWD/log
    mkdir -p "$stubs" "$home"
    cat > "$stubs/codesign" <<'EOF'
    #!/bin/sh
    echo "codesign $*" >> "$LOG"
    for last; do :; done
    mode= identity=
    while [ $# -gt 0 ]; do
      case "$1" in
        --verify) mode=verify ;;
        --force) mode=sign ;;
        --sign) identity=$2; shift ;;
      esac
      shift
    done
    case "$mode" in
      verify) test -f "$last/Contents/_CodeSignature/CodeResources" ;;
      sign)
        case "''${CODESIGN_ALLOCATE:-}" in */bin/codesign_allocate) ;; *) exit 3 ;; esac
        if [ "$identity" = - ]; then
          [ -z "''${FAIL_ADHOC:-}" ] || exit 1
        else
          [ -z "''${FAIL_SIGN:-}" ] || exit 1
        fi
        mkdir -p "$last/Contents/_CodeSignature" && echo "$identity" > "$last/Contents/_CodeSignature/CodeResources" ;;
      *) exit 2 ;;
    esac
    EOF
    printf '#!/bin/sh\necho "launchctl $*" >> "$LOG"\nexit 113\n' > "$stubs/launchctl"
    chmod +x "$stubs"/*
    stub() {
      sed -e "s|${home}|$home|g" -e "s|/usr/bin/codesign|$stubs/codesign|g" \
        -e "s|/bin/launchctl|$stubs/launchctl|g" "$@"
    }
    stub $out/sign.sh > signA.sh
    stub -e "s|${fake}|${fakeB}|g" $out/sign.sh > signB.sh
    stub $out/unsign.sh > unsign.sh
    app=$home/Applications/Vestal.app sig=Contents/_CodeSignature/CodeResources
    stamp=$home/.local/state/vestal/signed-app
    A='${fake}/Applications/Vestal.app' B='${fakeB}/Applications/Vestal.app'
    activate() { (export LOG=$log; set -euo pipefail; source "./$1.sh") 2> err; }
    fail() { echo "hm-module: sign step: $*" >&2; cat err >&2; exit 1; }
    build() { grep -qxF "echo $1 \"\$@\"" "$app/Contents/MacOS/vestal"; }
    signed() { grep -qxF -- "$1" "$app/$sig"; }

    activate signA
    build vestal-fake && signed '${identity}' || fail "first run did not install A signed"
    grep -qxF "$A ${identity}" "$stamp" || fail "no stamp"
    grep -q -- '--timestamp=none' "$log" || fail "codesign without --timestamp=none"
    grep -q 'kickstart -k gui/[0-9]*/org.nix-community.home.vestal' "$log" || fail "no agent restart"
    test ! -e "$app.nix-new" || fail "temporary copy left behind"

    : > "$log"; activate signA
    ! grep -q -- --force "$log" || fail "re-signed an unchanged copy"

    activate signB
    build vestal-fake-b && signed '${identity}' || fail "update to B not signed"
    grep -qxF "$B ${identity}" "$stamp" || fail "stamp not updated to B"
    test ! -e "$app.nix-old" -a ! -e "$app.nix-new" || fail "swap left files behind"

    # Signing fails: a copy signed with the identity stays, even an older build.
    FAIL_SIGN=1 activate signA
    grep -q 'keeping .*signed with' err || fail "no warning when signing fails"
    build vestal-fake-b && signed '${identity}' || fail "a failed signing replaced a signed copy"
    grep -qxF "$B ${identity}" "$stamp" || fail "a failed signing changed the stamp"

    # ... and on a first install, the build goes in signed ad hoc.
    rm -rf "$app" "$stamp"
    FAIL_SIGN=1 activate signA
    grep -q 'ad hoc' err || fail "no ad-hoc warning"
    build vestal-fake && signed - || fail "no ad-hoc copy when signing fails on first install"
    grep -qxF "$A -" "$stamp" || fail "no ad-hoc stamp"

    : > "$log"; FAIL_SIGN=1 activate signA
    ! grep -q -- '--sign -' "$log" || fail "re-installed the same ad-hoc build"

    # A installed ad hoc, then an update to B while signing still fails.
    FAIL_SIGN=1 activate signB
    build vestal-fake-b && signed - || fail "kept an ad-hoc copy of an old build"
    grep -qxF "$B -" "$stamp" || fail "stamp not updated to B ad hoc"

    FAIL_SIGN=1 FAIL_ADHOC=1 activate signA
    build vestal-fake && test ! -e "$app/Contents/_CodeSignature" \
      && cmp -s "$app/Contents/MacOS/vestal" "$A/Contents/MacOS/vestal" \
      || fail "not installed as built when ad-hoc signing fails too"

    mkdir -p "$app.nix-old/Vestal.app"
    (rm() { case "$*" in *.nix-old*) return 1 ;; *) command rm "$@" ;; esac; }; activate signB)
    grep -q 'cannot remove' err || fail "no warning when the old copy can't be removed"
    build vestal-fake && test ! -e "$app.nix-old/Vestal.app/Contents" -a ! -e "$app.nix-new" \
      || fail "moved the app into a stale old copy"
    rm -rf "$app.nix-old"

    rm -rf "$app"
    DRY_RUN=1 activate signA | grep -q 'Would install' || fail "no dry-run message"
    test ! -e "$app" || fail "a dry run installed the copy"

    # signingIdentity unset: remove the copy only when the stamp says it is ours.
    activate signA
    DRY_RUN=1 activate unsign | grep -q 'Would remove' || fail "no dry-run removal message"
    test -d "$app" || fail "a dry run removed the copy"
    activate unsign
    test ! -e "$app" -a ! -e "$stamp" || fail "the signed copy was not removed"
    mkdir -p "$app"; activate unsign
    test -d "$app" || fail "removed an app without a stamp"
  ''
