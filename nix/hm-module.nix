# Home Manager module for vestal (programs.vestal). flake.nix exports it as
# homeManagerModules.default; `self` is the vestal flake, for the default
# package.
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    literalExpression
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    types
    ;
  inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux system;

  cfg = config.programs.vestal;
  json = pkgs.formats.json { };
  home = config.home.homeDirectory;
  signing = isDarwin && cfg.signingIdentity != null;

  storeApp = "${cfg.package}/Applications/Vestal.app";
  # Where activation installs the signed copy (signingIdentity).
  signedApp = "${home}/Applications/Vestal.app";
  # "<store app> <identity>" of the copy activation installed, "-" for the
  # identity when it had to sign ad hoc. It marks the copy as ours, and lets
  # activation re-sign only when the build or the identity changes.
  signedStamp = "${config.xdg.stateHome}/vestal/signed-app";
  appExecutable = "${if signing then signedApp else storeApp}/Contents/MacOS/vestal";

  # `vestal` on PATH. With a signing identity it runs the signed copy, so a
  # dashboard it starts has the stable identity too.
  cliPackage =
    if signing then
      pkgs.writeShellScriptBin "vestal" ''
        app=${lib.escapeShellArg "${signedApp}/Contents/MacOS/vestal"}
        if [ -x "$app" ]; then exec "$app" "$@"; fi
        exec ${lib.escapeShellArg "${storeApp}/Contents/MacOS/vestal"} "$@"
      ''
    else
      cfg.package;

  # PATH for the login service: Nix profiles first, then Homebrew and the
  # system. Command sources look up their executables here.
  servicePath = lib.concatStringsSep ":" (
    lib.unique (
      lib.optionals isLinux [ "/run/wrappers/bin" ]
      ++ [
        "${config.home.profileDirectory}/bin"
        "${home}/.nix-profile/bin"
        "/etc/profiles/per-user/${config.home.username}/bin"
        "/run/current-system/sw/bin"
        "/nix/var/nix/profiles/default/bin"
      ]
      ++ lib.optionals isDarwin [ "/opt/homebrew/bin" ]
      ++ [
        "/usr/local/bin"
        "/usr/bin"
        "/bin"
        "/usr/sbin"
        "/sbin"
      ]
    )
  );

  # Copies Vestal.app out of the store and signs it (Nix builds can't reach
  # the keychain). Never fails the activation. If signing with the identity
  # fails, it warns and keeps the installed copy when that one was signed with
  # an identity (its permissions survive) or already is this build; otherwise
  # it installs this build signed ad hoc, or as built if even that fails (the
  # linker already signed the binary ad hoc).
  signScript = ''
    vestalSignApp() {
      local src=${lib.escapeShellArg storeApp}
      local dst=${lib.escapeShellArg signedApp}
      local identity=${lib.escapeShellArg cfg.signingIdentity}
      local stamp=${lib.escapeShellArg signedStamp}
      local agent=${lib.escapeShellArg (lib.optionalString cfg.launchAtLogin config.launchd.agents.vestal.config.Label)}
      # codesign needs codesign_allocate, which only Xcode or its command line
      # tools provide otherwise.
      local -x CODESIGN_ALLOCATE=${lib.escapeShellArg "${pkgs.cctools}/bin/${pkgs.cctools.targetPrefix}codesign_allocate"}
      local tmp="$dst.nix-new" old="$dst.nix-old" have="" was signedWith
      if [[ -f "$stamp" && -d "$dst" ]]; then have=$(< "$stamp"); fi
      was=''${have#* }

      if [[ "$have" == "$src $identity" ]] \
        && /usr/bin/codesign --verify --deep "$dst" >/dev/null 2>&1; then
        return 0
      fi

      mkdir -p "''${dst%/*}" "''${stamp%/*}" || return 1
      if [[ -e "$tmp" ]]; then chmod -R u+w "$tmp" && rm -rf "$tmp" || return 1; fi
      # Store files are read-only; codesign rewrites the binary.
      cp -R "$src" "$tmp" && chmod -R u+w "$tmp" || return 1

      signedWith=$identity
      if ! /usr/bin/codesign --force --deep --timestamp=none --sign "$identity" "$tmp"; then
        echo "vestal: codesign with '$identity' failed (see: security find-identity -v -p codesigning)" >&2
        if [[ -n "$have" && "$was" != - ]]; then
          echo "vestal: keeping $dst, signed with '$was', until signing works" >&2
          rm -rf "$tmp"
          return 0
        fi
        if [[ "$have" == "$src -" ]]; then
          # Already this build, signed ad hoc.
          rm -rf "$tmp"
          return 0
        fi
        echo "vestal: installing this build as $dst, signed ad hoc: macOS asks for calendar and automation access again after every vestal update until signing works" >&2
        if ! /usr/bin/codesign --force --deep --timestamp=none --sign - "$tmp"; then
          rm -rf "$tmp" && cp -R "$src" "$tmp" && chmod -R u+w "$tmp" || return 1
        fi
        signedWith=-
      fi

      # Swap the copies by renaming, never overwrite in place: a running
      # vestal keeps its old binary until it restarts below, and a failure
      # leaves a complete app behind.
      if [[ -e "$old" ]]; then chmod -R u+w "$old"; rm -rf "$old"; fi
      if [[ -e "$old" ]]; then
        echo "vestal: cannot remove $old" >&2
        rm -rf "$tmp"
        return 1
      fi
      if [[ -e "$dst" ]] && ! mv "$dst" "$old"; then
        echo "vestal: cannot replace $dst; the terminal may need App Management access (System Settings > Privacy & Security)" >&2
        rm -rf "$tmp"
        return 1
      fi
      mv "$tmp" "$dst" || { [[ -e "$old" ]] && mv "$old" "$dst"; return 1; }
      if [[ -e "$old" ]]; then chmod -R u+w "$old" && rm -rf "$old"; fi
      echo "$src $signedWith" > "$stamp"

      # The agent's plist doesn't change with the build (it points at $dst),
      # so restart the agent to run the new copy. Fails when not loaded yet.
      if [[ -n "$agent" ]]; then
        /bin/launchctl kickstart -k "gui/$UID/$agent" >/dev/null 2>&1 || true
      fi
    }

    if [[ -v DRY_RUN ]]; then
      echo "Would install and sign" ${lib.escapeShellArg signedApp}
    else
      vestalSignApp || echo "vestal: could not update" ${lib.escapeShellArg signedApp} >&2
    fi
  '';

  # With signingIdentity unset, removes the copy activation installed while
  # it was set. The stamp says the copy is ours; an app without one is never
  # touched.
  unsignScript = ''
    vestalRemoveSignedApp() {
      local dst=${lib.escapeShellArg signedApp} p
      for p in "$dst" "$dst.nix-new" "$dst.nix-old"; do
        if [[ -e "$p" ]]; then chmod -R u+w "$p" && rm -rf "$p" || return 1; fi
      done
      rm -f ${lib.escapeShellArg signedStamp}
    }

    if [[ -f ${lib.escapeShellArg signedStamp} ]]; then
      if [[ -v DRY_RUN ]]; then
        echo "Would remove" ${lib.escapeShellArg signedApp}
      else
        vestalRemoveSignedApp \
          || echo "vestal: could not remove" ${lib.escapeShellArg signedApp} "(the terminal may need App Management access)" >&2
      fi
    fi
  '';
in
{
  options.programs.vestal = {
    enable = mkEnableOption "vestal, a keypress-toggled dashboard overlay";

    package = mkOption {
      type = types.package;
      default =
        self.packages.${system}.default
          or (throw "programs.vestal: the vestal flake has no package for ${system}");
      defaultText = literalExpression "vestal.packages.\${pkgs.stdenv.hostPlatform.system}.default";
      description = "The vestal package to use.";
    };

    settings = mkOption {
      inherit (json) type;
      default = { };
      example = literalExpression ''
        {
          hotkey = "f3";
          platform.linux.hotkey = "home";
          theme.background = "blur";
        }
      '';
      description = ''
        Vestal configuration, written to
        {file}`$XDG_CONFIG_HOME/vestal/config.json` with `version = 1` added
        unless set. Vestal layers it over its built-in defaults: objects merge
        key by key, arrays and scalars replace, and `null` removes a default.
        See docs/CONFIG.md in the vestal repository for every key.

        The default, `{ }`, writes no file: vestal then runs on its built-in
        defaults, or on a config file you manage yourself.
      '';
    };

    launchAtLogin = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Start vestal hidden (`vestal daemon`) at login and restart it if it
        crashes. On macOS this is a launchd agent. On Linux it becomes a
        systemd user service once the package supports a daemon there
        (`passthru.supportsDaemon`); until then this option does nothing.
      '';
    };

    signingIdentity = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "Apple Development: Jane Doe (ABCDE12345)";
      description = ''
        macOS only; ignored on Linux. A code signing identity from your
        keychain (list them with `security find-identity -v -p codesigning`).
        When set, activation copies Vestal.app to
        {file}`~/Applications/Vestal.app` and runs
        `codesign --force --deep --sign` on the copy, and the launch agent
        and the `vestal` command run that copy. A stable signature keeps the
        calendar and automation permissions across rebuilds; Nix builds cannot
        reach the keychain, so this happens at activation. When it is unset
        again, activation removes that copy (only the one it installed).
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = builtins.isAttrs cfg.settings;
          message = "programs.vestal.settings must be an attribute set (a JSON object).";
        }
      ];

      home.packages = [ cliPackage ];

      xdg.configFile."vestal/config.json" = mkIf (cfg.settings != { }) {
        source = json.generate "vestal-config.json" (
          if builtins.isAttrs cfg.settings then { version = 1; } // cfg.settings else cfg.settings
        );
      };

      # Apply the new config now. `reload` only talks to a running instance
      # (it never starts one) and fails when there is none, or when that
      # instance predates `reload`; neither may fail the activation.
      home.activation.vestalReload = lib.hm.dag.entryAfter [ "linkGeneration" "setupLaunchAgents" ] ''
        run ${pkgs.coreutils}/bin/timeout 5 ${lib.getExe cfg.package} reload >/dev/null 2>&1 || true
      '';
    }

    (mkIf (isDarwin && cfg.launchAtLogin) {
      launchd.agents.vestal = {
        enable = true;
        config = {
          ProgramArguments = [
            appExecutable
            "daemon"
          ];
          RunAtLoad = true;
          # Restart after a crash, but not after `vestal quit` or when another
          # instance already runs: both exit 0.
          KeepAlive.SuccessfulExit = false;
          # A UI that has to appear on a keypress: no background throttling.
          ProcessType = "Interactive";
          EnvironmentVariables = {
            PATH = servicePath;
            XDG_CONFIG_HOME = config.xdg.configHome;
          };
          StandardOutPath = "${home}/Library/Logs/vestal.log";
          StandardErrorPath = "${home}/Library/Logs/vestal.log";
        };
      };
    })

    (mkIf (isLinux && cfg.launchAtLogin && (cfg.package.supportsDaemon or false)) {
      systemd.user.services.vestal = {
        Unit = {
          Description = "Vestal dashboard";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Service = {
          ExecStart = "${lib.getExe cfg.package} daemon";
          ExecReload = "${lib.getExe cfg.package} reload";
          Restart = "on-failure";
          Environment = [
            "PATH=${servicePath}"
            "XDG_CONFIG_HOME=${config.xdg.configHome}"
          ];
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    })

    (mkIf signing {
      # After the files are written, before launchd (re)loads the agent that
      # runs the copy.
      home.activation.vestalSignApp =
        lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
          signScript;
    })

    (mkIf (isDarwin && !signing) {
      # After launchd has moved the agent off the copy.
      home.activation.vestalRemoveSignedApp = lib.hm.dag.entryAfter [
        "writeBoundary"
        "setupLaunchAgents"
      ] unsignScript;
    })
  ]);
}
