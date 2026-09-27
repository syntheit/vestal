# Home Manager module for vestal (programs.vestal). flake.nix exports it as
# homeManagerModules.default; `self` is the vestal flake, for the default
# package.
self:
{
  config,
  options,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    literalExpression
    literalMD
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    types
    ;
  inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux system;

  cfg = config.programs.vestal;
  opts = options.programs.vestal;
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

  # Programs the daemon runs besides the user's: on Linux, playerctl for the
  # media source and wpctl (wireplumber) for volume.
  platformPackages = lib.optionals isLinux [
    pkgs.playerctl
    pkgs.wireplumber
  ];

  # PATH for the login service: extraPackages and the platform's programs
  # first, then Nix profiles, Homebrew and the system. Command sources, `run`
  # actions and command secrets look up their executables here.
  servicePath = lib.concatStringsSep ":" (
    lib.unique (
      map (p: "${lib.getBin p}/bin") (cfg.extraPackages ++ platformPackages)
      ++ lib.optionals isLinux [ "/run/wrappers/bin" ]
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

  # MARK: Hyprland
  #
  # The hotkey vestal would use on Linux, merged as vestal merges its layers:
  # a `hotkey` key in platform.linux wins (even null), then the top level.
  linuxHotkey =
    let
      s = if builtins.isAttrs cfg.settings then cfg.settings else { };
      platform = if builtins.isAttrs (s.platform or null) then s.platform else { };
      linux = if builtins.isAttrs (platform.linux or null) then platform.linux else { };
    in
    if linux ? hotkey then linux.hotkey else s.hotkey or null;

  # A `theme` key as vestal reads it on Linux: platform.linux.theme's wins
  # (even null), then the top level's.
  linuxTheme =
    key:
    let
      s = if builtins.isAttrs cfg.settings then cfg.settings else { };
      platform = if builtins.isAttrs (s.platform or null) then s.platform else { };
      linux = if builtins.isAttrs (platform.linux or null) then platform.linux else { };
      own = if builtins.isAttrs (linux.theme or null) then linux.theme else { };
      top = if builtins.isAttrs (s.theme or null) then s.theme else { };
    in
    if own ? ${key} then own.${key} else top.${key} or null;

  # Whether the dashboard wants Hyprland's blur behind it: only with
  # `theme.backdrop = "compositor"`. The default, "self", blurs vestal's own
  # capture of the screen in an opaque window, where a blur rule would only
  # cost GPU time; "none" asks for no blur, and a `none` background is opaque.
  # If vestal can't capture the screen it falls back to a translucent window,
  # unblurred here; set "compositor" explicitly on a compositor without
  # screen capture.
  compositorBlur = linuxTheme "backdrop" == "compositor" && linuxTheme "background" != "none";

  # vestal's hotkey grammar (Sources/VestalCore/Hotkey.swift) in Hyprland's
  # bind syntax: modifiers as Hyprland names them, keys as XKB keysym names.
  hyprModifiers = {
    cmd = "SUPER";
    command = "SUPER";
    super = "SUPER";
    ctrl = "CTRL";
    control = "CTRL";
    alt = "ALT";
    opt = "ALT";
    option = "ALT";
    shift = "SHIFT";
  };
  hyprKeys =
    lib.genAttrs (lib.stringToCharacters "abcdefghijklmnopqrstuvwxyz") lib.toUpper
    // lib.genAttrs (lib.stringToCharacters "0123456789") lib.id
    // lib.listToAttrs (map (n: lib.nameValuePair "f${toString n}" "F${toString n}") (lib.range 1 20))
    // {
      space = "space";
      escape = "Escape";
      esc = "Escape";
      home = "Home";
      end = "End";
    };
  # Keys that may stand alone; the others need cmd, ctrl or alt, as in vestal.
  hyprStandalone = map (n: "F${toString n}") (lib.range 1 20) ++ [
    "Home"
    "End"
  ];

  # "MODS, key" for a vestal hotkey string, or null when vestal would not
  # accept it either.
  hyprCombo =
    hotkey:
    let
      parts = map (p: lib.toLower (lib.trim p)) (lib.splitString "+" hotkey);
      modNames = lib.filter (p: hyprModifiers ? ${p}) parts;
      keyNames = lib.filter (p: !(hyprModifiers ? ${p})) parts;
      mods = map (p: hyprModifiers.${p}) modNames;
      key = hyprKeys.${lib.head keyNames} or null;
    in
    if
      lib.length keyNames == 1
      && key != null
      && lib.length (lib.unique mods) == lib.length mods
      && (lib.elem key hyprStandalone || lib.any (m: m != "SHIFT") mods)
    then
      "${lib.concatStringsSep " " mods}, ${key}"
    else
      null;

  derivedBind = if builtins.isString linuxHotkey then hyprCombo linuxHotkey else null;

  # A layer rule for the dashboard's layer surface (namespace `vestal`), in
  # the `match:` rule syntax of Hyprland 0.53 and later.
  layerRule = effect: "${effect}, match:namespace ^(vestal)$";
  # Home Manager's Hyprland module before configType existed wrote hyprlang.
  hyprlang = (config.wayland.windowManager.hyprland.configType or "hyprlang") == "hyprlang";

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

  # MARK: Claude Code's status line
  #
  # Claude Code writes ~/.claude/settings.json itself, so it is edited in
  # place (never linked): `statusLine` is added when there is none, and
  # updated when it is vestal's own from another build (anything after
  # `claude-statusline`, such as --then, is kept). Any other status line is
  # left alone with a warning. Never fails the activation.
  claudeSettings = "${home}/.claude/settings.json";
  claudeStatusCommand = "${lib.getExe cliPackage} claude-statusline";
  claudeStatusLineScript = ''
    vestalClaudeStatusLine() {
      local settings=${lib.escapeShellArg claudeSettings}
      local want=${lib.escapeShellArg claudeStatusCommand}
      local jq=${lib.escapeShellArg (lib.getExe pkgs.jq)}
      # Ours: a vestal from the store, then exactly claude-statusline.
      local ours='^/nix/store/[^/ ]+/bin/vestal claude-statusline( |$)'
      local current="" state=none filter tmp
      if [[ -L "$settings" ]]; then
        local target
        target=$(${pkgs.coreutils}/bin/realpath -e "$settings" 2>/dev/null) || target=""
        if [[ -z "$target" || "$target" == /nix/store/* ]]; then
          echo "vestal: $settings is a link Home Manager or Nix owns; add the statusLine there: {\"type\": \"command\", \"command\": \"$want\"}" >&2
          return 0
        fi
        settings=$target
      fi
      if [[ -e "$settings" ]]; then
        if ! state=$("$jq" -r 'if type != "object" then error("not an object")
            elif has("statusLine") | not then "none"
            elif (.statusLine | type) == "object" and .statusLine.type == "command"
                 and (.statusLine.command | type) == "string" then "command"
            else "other" end' "$settings" 2>/dev/null); then
          echo "vestal: $settings is not a JSON object; leaving it alone" >&2
          return 0
        fi
        if [[ "$state" == command ]]; then current=$("$jq" -r '.statusLine.command' "$settings"); fi
      fi

      if [[ "$state" == none ]]; then
        filter='. + {statusLine: {type: "command", command: $want}}'
      elif [[ "$state" == command && "$current" =~ $ours ]]; then
        [[ "''${current%% *} claude-statusline" == "$want" ]] && return 0
        filter='.statusLine.command |= ($want + (ltrimstr(capture("^(?<p>[^ ]+ claude-statusline)").p)))'
      else
        echo "vestal: $settings already has a statusLine; leaving it alone. To show Claude usage in vestal, run \`$want --then <your command>\` as the status line (vestal docs ai-usage)" >&2
        return 0
      fi

      if [[ -v DRY_RUN ]]; then
        echo "Would set the statusLine in $settings to $want"
        return 0
      fi
      mkdir -p "''${settings%/*}" || return 1
      tmp=$(mktemp "$settings.vestal.XXXXXX") || return 1
      if [[ -e "$settings" ]]; then
        "$jq" --arg want "$want" "$filter" "$settings" > "$tmp" \
          && ${pkgs.coreutils}/bin/chmod --reference="$settings" "$tmp" \
          && mv "$tmp" "$settings" || { rm -f "$tmp"; return 1; }
      else
        "$jq" -n --arg want "$want" "{} | $filter" > "$tmp" && chmod 600 "$tmp" \
          && mv "$tmp" "$settings" || { rm -f "$tmp"; return 1; }
      fi
    }

    vestalClaudeStatusLine || echo "vestal: could not update" ${lib.escapeShellArg claudeSettings} >&2
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

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      example = literalExpression "[ pkgs.gh pkgs.curl ]";
      description = ''
        Packages whose programs the daemon can run: they come first on the
        PATH of the launch agent (macOS) or the systemd user service (Linux),
        where `command` sources, `run` actions and `command` secrets look
        their programs up. Add what the config calls, such as `gh` or
        `foyer-api`. On Linux, `playerctl` and `wireplumber` (`wpctl`), which
        the built-in `media` and `system` sources use, are always added.
      '';
    };

    launchAtLogin = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Start vestal hidden (`vestal daemon`) at login and restart it if it
        crashes. On macOS this is a launchd agent. On Linux it is a systemd
        user service (for packages with `passthru.supportsDaemon`), which
        runs vestal headless until the Linux UI exists.
      '';
    };

    hyprland = {
      enable = mkEnableOption ''
        the Hyprland integration (Linux only; ignored on macOS): a bind that
        runs `vestal toggle`, and, with `theme.backdrop = "compositor"`,
        layer rules that blur behind the dashboard. It
        adds to {option}`wayland.windowManager.hyprland.settings` and needs
        Hyprland 0.53 or later (the `match:` rule syntax)
      '';

      bind = mkOption {
        type = types.nullOr types.str;
        default = derivedBind;
        defaultText = literalMD ''
          The hotkey vestal uses on Linux (`settings.platform.linux.hotkey`,
          else `settings.hotkey`) in Hyprland's syntax: `"home"` becomes
          `", Home"`, `"super+d"` (or `"cmd+d"`) `"SUPER, D"`, `"ctrl+alt+f3"`
          `"CTRL ALT, F3"`. `null` when there is no hotkey.
        '';
        example = "SUPER SHIFT, D";
        description = ''
          The modifiers and key of the Hyprland bind that runs
          `vestal toggle`, as a `bind` line has them before the dispatcher
          (`"MODS, key"`). `null` adds no bind. vestal registers no hotkey of
          its own on Linux, so this bind is what its hotkey setting does there.
        '';
      };

      blur = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Blur what is behind the dashboard (the `blur` layer rule) when the
          settings choose `theme.backdrop = "compositor"` (in
          `platform.linux.theme` or `theme`). With the default backdrop,
          `"self"`, vestal blurs its own capture of the screen in an opaque
          window and no rule is added.
        '';
      };

      ignoreAlpha = mkOption {
        type = types.nullOr (types.numbers.between 0 1);
        default = 0.3;
        description = ''
          The `ignore_alpha` layer rule, added with the `blur` rule only:
          parts of the dashboard more transparent than this get no blur
          behind them. `null` leaves the rule out. Keep it below vestal's
          `theme.dim` (0.5 by default), the opacity of the dashboard's tint.
        '';
      };

      animation = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "fade";
        description = ''
          The `animation` layer rule, a Hyprland layer animation style such
          as `"fade"`, `"slide top"` or `"popin 90%"`. `null` keeps the
          compositor's layer animation. vestal also fades its content in and
          out itself.
        '';
      };

      noAnim = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Turn off Hyprland's open and close animation for the dashboard (the
          `no_anim` layer rule), leaving only vestal's own fade.
        '';
      };
    };

    claudeStatusLine.enable = mkEnableOption ''
      Claude Code's status line as `vestal claude-statusline`, which keeps
      the Claude plan's rate limits for the `claude` source (Pro and Max
      plans; see `vestal docs ai-usage`). Activation edits
      {file}`~/.claude/settings.json` in place (Claude Code writes it too, so
      it is never a link): it adds `statusLine` when there is none, and
      updates vestal's own after a rebuild. Another status line is left
      alone with a warning; chain it with `vestal claude-statusline --then
      <command>` yourself'';

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
        {
          # Only while the bind is derived: a set bind (even null) wins.
          assertion =
            !(
              isLinux
              && cfg.hyprland.enable
              && linuxHotkey != null
              && derivedBind == null
              && opts.hyprland.bind.highestPrio >= (lib.mkOptionDefault null).priority
            );
          message = ''
            programs.vestal.hyprland: the hotkey ${builtins.toJSON linuxHotkey} is not one vestal accepts (see
            docs/CONFIG.md), so it has no Hyprland bind. Fix it, or set programs.vestal.hyprland.bind.'';
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

    # The session's display variables (WAYLAND_DISPLAY, DISPLAY,
    # HYPRLAND_INSTANCE_SIGNATURE, ...) come from the systemd user manager's
    # environment. The compositor has to import them before it starts
    # graphical-session.target: Home Manager's Hyprland module does with
    # `wayland.windowManager.hyprland.systemd.enable` (the default), and so
    # does UWSM. The condition keeps the service from starting, and failing,
    # in a session that didn't.
    (mkIf (isLinux && cfg.launchAtLogin && (cfg.package.supportsDaemon or false)) {
      systemd.user.services.vestal = {
        Unit = {
          Description = "Vestal dashboard";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
          ConditionEnvironment = [
            "|WAYLAND_DISPLAY"
            "|DISPLAY"
          ];
          # Without a display the daemon exits 1 at once. Ten tries 2 s
          # apart (about 20 s) cover a compositor that isn't accepting
          # clients yet; systemd's default (5 in 10 s) gives up after 10 s.
          StartLimitIntervalSec = 60;
          StartLimitBurst = 10;
        };
        Service = {
          ExecStart = "${lib.getExe cfg.package} daemon";
          ExecReload = "${lib.getExe cfg.package} reload";
          # Not after `vestal quit`, or when another instance already runs:
          # both exit 0.
          Restart = "on-failure";
          RestartSec = 2;
          Environment = [
            "PATH=${servicePath}"
            "XDG_CONFIG_HOME=${config.xdg.configHome}"
          ];
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    })

    # The lines below are hyprlang. Home Manager's Lua output would turn each
    # into a call with the wrong name and arguments, so there it only warns.
    (mkIf (isLinux && cfg.hyprland.enable && !hyprlang) {
      warnings = [
        ''
          programs.vestal.hyprland writes hyprlang `bind` and `layerrule` lines, but
          wayland.windowManager.hyprland.configType is not "hyprlang", so it adds nothing.
          Bind `vestal toggle` and add layer rules for the namespace `vestal` yourself.''
      ];
    })

    (mkIf (isLinux && cfg.hyprland.enable && hyprlang) {
      wayland.windowManager.hyprland.settings = {
        bind = lib.optional (cfg.hyprland.bind != null) "${cfg.hyprland.bind}, exec, ${lib.getExe cfg.package} toggle";
        layerrule =
          lib.optional (cfg.hyprland.blur && compositorBlur) (layerRule "blur on")
          ++ lib.optional (cfg.hyprland.blur && compositorBlur && cfg.hyprland.ignoreAlpha != null) (
            layerRule "ignore_alpha ${toString cfg.hyprland.ignoreAlpha}"
          )
          ++ lib.optional (cfg.hyprland.animation != null) (layerRule "animation ${cfg.hyprland.animation}")
          ++ lib.optional cfg.hyprland.noAnim (layerRule "no_anim on");
      };
    })

    (mkIf cfg.claudeStatusLine.enable {
      home.activation.vestalClaudeStatusLine = lib.hm.dag.entryAfter [ "writeBoundary" ] claudeStatusLineScript;
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
