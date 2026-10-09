import Foundation

// MARK: - Homelab presets
//
// Five widgets for a home server or a small fleet, and the source templates
// ("data packs") that feed them, written in the public config language like
// the other built-in templates:
//
//   containers       Docker or Podman containers: state, CPU and memory
//                    (sources dockerPs, dockerStats)
//   tailnet          Tailscale devices (source tailscaleStatus)
//   uptimeMonitors   status dots, bars and incidents of monitored services
//                    (sources uptimeKuma, healthchecks)
//   backups          one row per backup job, from a directory of small JSON
//                    status files (a `file` source on a directory)
//   transfers        downloads and long jobs with progress (source aria2, or
//                    any progress file)
//
// Each source's `transform` turns the program's or API's own answer into one
// small, documented shape, so a widget never depends on a tool's field
// names. The jq programs below are written here as plain text and put into
// the JSON by `jq(_:)`; they cannot hold `#` comments, as the lines are
// joined.

extension DefaultPresets {
    // MARK: jq

    /// A jq program as the text of a JSON string: quotes and backslashes
    /// escaped, lines trimmed and joined.
    static func jq(_ program: String) -> String {
        program.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Docker prints one JSON object per line, Podman one array: both read.
    private static let containerRows = #"""
    def rows: . as $t | try ($t | fromjson | if type == "array" then . else [.] end) catch [$t | split("\n")[] | select(length > 0) | fromjson];
    """#

    /// `docker ps -a --format json` (raw text) → `[{name, image, state, kind, code, text}]`. `kind` is one of
    /// up, starting, unhealthy, restarting, paused, exited, failed, created; `text` the status, shortened
    /// ("up 12d", "exited (1) 2h ago").
    static let containerListJQ = containerRows + #"""
    def unit: {second: "s", minute: "m", hour: "h", day: "d", week: "w", month: "mo", year: "y"}[.];
    def short: ascii_downcase
      | gsub("less than a second"; "<1s")
      | gsub("about an? (?<u>second|minute|hour|day|week|month|year)"; "~1" + (.u | unit))
      | gsub("(?<n>[0-9]+) (?<u>second|minute|hour|day|week|month|year)s?"; .n + (.u | unit))
      | sub(" \\(healthy\\)"; "");
    rows | map(
      (if (.Names | type) == "array" then .Names[0] else .Names end) as $name
      | (.Status // "") as $status
      | ((.State // "") | ascii_downcase) as $state
      | ((($status | capture("\\((?<c>[0-9]+)\\)")? | .c | tonumber) // .ExitCode) // null) as $code
      | {
          name: $name,
          image: .Image,
          state: $state,
          code: $code,
          text: ($status | short),
          kind: (
            if $state == "running" then
              (if (($status | test("unhealthy"; "i")) or .HealthStatus == "unhealthy") then "unhealthy"
               elif ($status | test("starting"; "i")) then "starting"
               elif ($status | test("paused"; "i")) then "paused"
               else "up" end)
            elif $state == "restarting" then "restarting"
            elif $state == "paused" then "paused"
            elif $state == "exited" then (if $code == null or $code == 0 then "exited" else "failed" end)
            elif $state == "dead" then "failed"
            else "created" end)
        })
    """#

    /// `docker stats --no-stream --format json` (raw text) → `[{name, cpu, mem}]`: percent and bytes.
    static let containerStatsJQ = containerRows + #"""
    def bytes: capture("^(?<n>[0-9.]+) ?(?<u>[A-Za-z]*)")
      | (.n | tonumber) * ({"B": 1, "kB": 1000, "KB": 1000, "KiB": 1024, "MB": 1000000, "MiB": 1048576, "GB": 1000000000, "GiB": 1073741824, "TB": 1000000000000, "TiB": 1099511627776}[.u] // 1);
    rows | map({
      name: (.Name // .name // .Container),
      cpu: (((.CPUPerc // .cpu_percent // .cpu) | tostring | rtrimstr("%") | tonumber?) // null),
      mem: (((.MemUsage // .mem_usage) | tostring | split(" / ")[0] | bytes?) // null)
    })
    """#

    /// `tailscale status --json` → `{state, tailnet, devices: [{name, ip, os, online, self, active, exitNode,
    /// usingExit, subnet, expired, tags, since, lastSeen}]}`, this device first, then online ones, by name.
    static let tailnetJQ = #"""
    def epoch: (try to_epoch catch null) | if . != null and . > 0 then . else null end;
    def device($self): {
      name: ((.DNSName // "" | split(".")[0]) | if . == "" then (.HostName // "?") else . end),
      ip: ((.TailscaleIPs // []) | map(select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))) | first // null),
      os: .OS,
      online: (.Online == true),
      self: $self,
      active: (.Active == true),
      exitNode: (.ExitNodeOption == true),
      usingExit: (.ExitNode == true),
      subnet: ((.PrimaryRoutes // []) | length > 0),
      expired: (.Expired == true),
      tags: (.Tags // []),
      since: ([(.LastHandshake | epoch), (.LastWrite | epoch), (.LastSeen | epoch)] | map(select(. != null)) | max),
      lastSeen: (.LastSeen | epoch)
    };
    {
      state: (.BackendState // "Unknown"),
      tailnet: (.CurrentTailnet.Name // null),
      devices: (
        if .BackendState != "Running" then []
        else ([.Self | device(true)] + [(.Peer // {}) | to_entries[] | .value | device(false)])
          | sort_by([(if .self then 0 elif .online then 1 else 2 end), (.name | ascii_downcase)])
        end)
    }
    """#

    /// The two answers of an Uptime Kuma status page (its page and its heartbeats, fetched together) → the
    /// monitors shape: `{notice, window, services: [{name, state, days, uptime, incident}]}`. `days` are 45
    /// bars of good, warn, bad or none (empty), oldest first: the page's last 45 heartbeats.
    static let uptimeKumaJQ = #"""
    def epoch: sub("\\.[0-9]+$"; "") | sub(" "; "T") | . + "Z" | (try to_epoch catch null);
    def bar: {"1": "good", "0": "bad", "2": "warn", "3": "warn"}[tostring] // "none";
    def spacing($b): if ($b | length) > 1 then ((($b[-1].time | epoch) - ($b[0].time | epoch)) / (($b | length) - 1)) else 60 end;
    def lastrun($b):
      reduce range(0; $b | length) as $i (null;
        $b[$i].status as $s
        | if $s == 1 or $s == 3 then (if . != null then .open = false else . end)
          elif . != null and .open then .end = $i | .down = (.down or $s == 0)
          else {start: $i, end: $i, open: true, down: ($s == 0)} end)
      | if . == null then null
        else ($b[.start].time | epoch) as $from
          | {status: (if .down then "down" else "degraded" end), at: $from, seconds: (($b[.end].time | epoch) - $from + spacing($b)), ongoing: .open} end;
    .[0] as $page
    | .[1] as $hb
    | ($page.publicGroupList // [] | map(.monitorList // []) | add // []) as $monitors
    | ($monitors | map(
        . as $m
        | ($hb.heartbeatList[($m.id | tostring)] // []) as $b
        | ($b | .[-45:]) as $last
        | {
            name: $m.name,
            state: (if ($b | length) == 0 then "unknown"
                    else ({"1": "up", "0": "down", "2": "degraded", "3": "maintenance"}[($b[-1].status | tostring)] // "unknown") end),
            days: (([range(0; 45 - ($last | length))] | map("none")) + ($last | map(.status | bar))),
            uptime: (($hb.uptimeList[(($m.id | tostring) + "_24")] // null) | if . == null then null else ((. * 10000 | round) / 100) end),
            incident: lastrun($b),
            spacing: spacing($b)
          })) as $services
    | {
        notice: (if $page.incident == null then null
                 else {text: ($page.incident.title // "Notice"), at: (($page.incident.createdDate // null) | if . == null then null else epoch end)} end),
        window: (if ($services | length) > 0 and ($services[0].spacing >= 72000) then "45 days" else "last 45 checks" end),
        services: ($services | map(del(.spacing)))
      }
    """#

    /// Healthchecks.io's `/api/v3/checks/` → the monitors shape. The list has no history: `days` and `uptime`
    /// are null, and each service carries `lastPing` and `nextPing` instead.
    static let healthchecksJQ = #"""
    def epoch: if . == null then null else (try to_epoch catch null) end;
    {
      notice: null,
      window: null,
      services: ((.checks // []) | map(
        (.last_ping | epoch) as $last
        | (.next_ping | epoch) as $next
        | ({"up": "up", "grace": "degraded", "down": "down", "paused": "paused"}[.status] // "unknown") as $state
        | {
            name: .name,
            state: $state,
            days: null,
            uptime: null,
            lastPing: $last,
            nextPing: $next,
            incident: (if $state == "down" and $next != null then {status: "down", at: ($next + (.grace // 0)), seconds: null, ongoing: true}
                       elif $state == "degraded" and $next != null then {status: "degraded", at: $next, seconds: null, ongoing: true}
                       else null end)
          }))
    }
    """#

    /// aria2's batch answer (tellActive and tellWaiting) → the progress shape `[{name, percent, detail, right,
    /// icon, color}]`; an RPC error fails the fetch.
    static let aria2JQ = #"""
    def part($answers; $id): (($answers | map(select(.id == $id)) | first | .result) // []);
    def num: tonumber? // 0;
    def basename: sub("\\?.*$"; "") | split("/") | map(select(length > 0)) | last // null;
    def item:
      (.totalLength | num) as $total
      | (.completedLength | num) as $done
      | (.downloadSpeed | num) as $speed
      | (.uploadSpeed | num) as $up
      | (.status // "") as $status
      | ((.bittorrent.info.name // null)
         // ((.files // [])[0].path // "" | if length > 0 then basename else null end)
         // ((.files // [])[0].uris[0].uri // null | if . != null then basename else null end)
         // .gid) as $name
      | {
          name: $name,
          percent: (if $total > 0 then ($done * 100 / $total) else null end),
          detail: (
            if $status == "paused" then "paused"
            elif $status == "waiting" then "queued"
            elif $total > 0 and $done >= $total then "seeding"
            elif $speed > 0 then (($speed | fmt_rate) + "/s")
            else "connecting" end),
          right: (
            if $status == "paused" or $status == "waiting" then (if $total > 0 then ($total | fmt_bytes) else "" end)
            elif $total > 0 and $done >= $total then (if $up > 0 then (($up | fmt_rate) + "/s up") else "" end)
            elif $speed > 0 and $total > $done then ((($total - $done) / $speed) | ceil | fmt_duration(2)) + " left"
            else "" end),
          icon: (if .bittorrent != null then "magnet" else "download" end),
          color: (if $status == "paused" then "warn" elif $status == "waiting" then "dim" elif ($total > 0 and $done >= $total) then "good" else "accent" end)
        };
    . as $answers
    | (($answers | map(select(.error != null)) | first) // null) as $failed
    | if $failed != null then error("aria2: " + ($failed.error.message // "request failed"))
      else (part($answers; "active") + part($answers; "waiting")) | map(item) end
    """#

    /// Seconds from a number or a duration text such as "26h" or "1d"; null otherwise.
    private static let secondsDef = #"""
    def secs: if type == "number" then . elif type == "string" then ((capture("^(?<n>[0-9.]+) ?(?<u>[smhdw])$")? | (.n | tonumber) * ({s: 1, m: 60, h: 3600, d: 86400, w: 604800}[.u])) // null) else null end;
    """#

    // MARK: Templates

    private static let aria2Keys = #"["gid", "status", "totalLength", "completedLength", "downloadSpeed", "uploadSpeed", "files", "bittorrent"]"#

    /// The templates, name → definition.
    public static var labJSON: String {
        #"""
        {
          "dockerPs": {
            "description": "Containers of a Docker or Podman host (docker ps -a --format json), as [{name, image, state, kind, code, text}]",
            "params": {
              "program": { "type": "string", "default": "docker", "description": "docker, podman, or the path of either" },
              "host": { "type": "string", "description": "Another machine's Docker host URL, such as ssh://nas (set as DOCKER_HOST and CONTAINER_HOST). Default: this machine" }
            },
            "source": {
              "type": "command",
              "argv": [{ "param": "program" }, "ps", "-a", "--format", "json"],
              "env": { "DOCKER_HOST": { "param": "host" }, "CONTAINER_HOST": { "param": "host" } },
              "parse": "raw", "timeout": "20s", "refresh": "15s", "when": "visible", "maxAge": "10m",
              "transform": "\#(jq(containerListJQ))"
            }
          },

          "dockerStats": {
            "description": "CPU and memory of running containers (docker stats --no-stream --format json), as [{name, cpu, mem}]",
            "params": {
              "program": { "type": "string", "default": "docker", "description": "docker, podman, or the path of either" },
              "host": { "type": "string", "description": "Another machine's Docker host URL, such as ssh://nas. Default: this machine" }
            },
            "source": {
              "type": "command",
              "argv": [{ "param": "program" }, "stats", "--no-stream", "--format", "json"],
              "env": { "DOCKER_HOST": { "param": "host" }, "CONTAINER_HOST": { "param": "host" } },
              "parse": "raw", "timeout": "30s", "refresh": "15s", "when": "visible", "maxAge": "10m",
              "transform": "\#(jq(containerStatsJQ))"
            }
          },

          "tailscaleStatus": {
            "description": "The tailnet (tailscale status --json), as {state, tailnet, devices: [...]}",
            "params": {
              "program": { "type": "string", "default": "tailscale", "description": "The CLI; on macOS with the app, /Applications/Tailscale.app/Contents/MacOS/Tailscale" }
            },
            "source": {
              "type": "command",
              "argv": [{ "param": "program" }, "status", "--json"],
              "timeout": "10s", "refresh": "10s", "when": "visible", "maxAge": "10m",
              "transform": "\#(jq(tailnetJQ))"
            }
          },

          "uptimeKuma": {
            "description": "Services of an Uptime Kuma status page, as {notice, window, services: [{name, state, days, uptime, incident}]}",
            "params": {
              "url": { "type": "string", "required": true, "description": "The Kuma server, such as https://status.example.com" },
              "slug": { "type": "string", "required": true, "description": "The status page's slug (the last part of its address)" }
            },
            "source": {
              "type": "http",
              "url": "{{ $url | rtrimstr(\"/\") }}/api/status-page/{{ $slug }}",
              "also": ["{{ $url | rtrimstr(\"/\") }}/api/status-page/heartbeat/{{ $slug }}"],
              "refresh": "1m", "when": "visible", "maxAge": "1h",
              "transform": "\#(jq(uptimeKumaJQ))"
            }
          },

          "healthchecks": {
            "description": "Checks of a Healthchecks.io project (/api/v3/checks/), as {notice, window, services: [{name, state, lastPing, nextPing, incident}]}",
            "params": {
              "url": { "type": "string", "default": "https://healthchecks.io", "description": "The server; change it for a self-hosted one" },
              "key": { "type": "text", "required": true, "description": "The project's API key, from a secret: \"{{ $secrets.healthchecks }}\"" }
            },
            "source": {
              "type": "http",
              "url": "{{ $url | rtrimstr(\"/\") }}/api/v3/checks/",
              "headers": { "X-Api-Key": { "param": "key" } },
              "refresh": "2m", "when": "visible", "maxAge": "1h",
              "transform": "\#(jq(healthchecksJQ))"
            }
          },

          "aria2": {
            "description": "Active and queued downloads of aria2 (JSON-RPC), as the progress shape [{name, percent, detail, right, icon, color}]",
            "params": {
              "url": { "type": "string", "default": "http://localhost:6800/jsonrpc", "description": "aria2's RPC endpoint" },
              "auth": { "type": "text", "description": "With an rpc-secret: \"token:{{ $secrets.aria2 }}\"" }
            },
            "source": {
              "type": "http",
              "url": "{{ $url }}",
              "method": "POST",
              "body": [
                { "jsonrpc": "2.0", "id": "active", "method": "aria2.tellActive", "params": [{ "param": "auth" }, \#(aria2Keys)] },
                { "jsonrpc": "2.0", "id": "waiting", "method": "aria2.tellWaiting", "params": [{ "param": "auth" }, 0, 20, \#(aria2Keys)] }
              ],
              "timeout": "5s", "refresh": "3s", "when": "visible", "maxAge": "5m",
              "transform": "\#(jq(aria2JQ))"
            }
          },

          "containers": {
            "description": "Containers of a Docker or Podman host: how many run and have exited, each one's state, CPU and memory",
            "params": {
              "title": { "type": "string", "default": "", "description": "A label before the badges, such as the host's name" },
              "program": { "type": "string", "default": "docker", "description": "docker, podman, or the path of either" },
              "host": { "type": "string", "description": "Another machine's Docker host URL, such as ssh://nas. Default: this machine" },
              "stats": { "type": "boolean", "default": true, "description": "Show CPU and memory (docker stats, which runs only while the dashboard is shown)" },
              "limit": { "type": "integer", "default": 10, "description": "Rows shown; containers that failed or are unhealthy are kept first" }
            },
            "widget": {
              "type": "stack", "gap": 8, "width": "fill",
              "source": { "type": "dockerPs", "program": { "param": "program" }, "host": { "param": "host" } },
              "input": "if type == \"array\" then map(select(type == \"object\")) else [] end",
              "vars": {
                "bad": "map(select(.kind == \"failed\" or .kind == \"unhealthy\" or .kind == \"restarting\"))",
                "shown": "($bad | .[:$limit]) as $b | $b + (map(select(.kind != \"failed\" and .kind != \"unhealthy\" and .kind != \"restarting\")) | .[:([$limit - ($b | length), 0] | max)]) | sort_by(if .state == \"running\" then 0 else 1 end)",
                "hidden": "length - ($shown | length)",
                "running": "map(select(.state == \"running\")) | length",
                "exited": "map(select(.state == \"exited\" or .state == \"dead\")) | length",
                "failed": "map(select(.kind == \"failed\")) | length",
                "trouble": "map(select(.kind == \"unhealthy\" or .kind == \"restarting\")) | length",
                "nameWidth": "[60, ((($shown | map(.name | length) | max) // 0) * 8 | ceil), 200] | sort | .[1]"
              },
              "children": [
                { "type": "row", "gap": 10, "style": { "size": 12 },
                  "when": "$title != \"\" or $running > 0 or $exited > 0 or $trouble > 0",
                  "children": [
                    { "type": "text", "when": "$title != \"\"", "text": "{{ $title }}", "style": { "weight": "semibold" } },
                    { "type": "badge", "when": "$running > 0", "text": "{{ $running }} running", "color": "good" },
                    { "type": "badge", "when": "$trouble > 0", "text": "{{ $trouble }} unhealthy", "color": "warn" },
                    { "type": "badge", "when": "$failed > 0", "text": "{{ $exited }} exited", "color": "bad" },
                    { "type": "badge", "when": "$failed == 0 and $exited > 0", "text": "{{ $exited }} exited", "color": "subtle" }
                  ] },
                { "type": "row", "gap": 10, "width": "fill", "when": "$shown | length > 0",
                  "style": { "size": 10, "weight": "semibold", "color": "dim", "tracking": 0.3, "case": "upper" },
                  "children": [
                    { "type": "text", "text": "Container", "width": { "expr": "$nameWidth" } },
                    { "type": "text", "text": "State", "width": "fill" },
                    { "type": "text", "when": "$stats", "text": "CPU", "width": 44, "align": "end" },
                    { "type": "text", "when": "$stats", "text": "Mem", "width": 62, "align": "end" }
                  ] },
                { "type": "list", "gap": 6, "width": "fill", "items": "$shown", "rowId": ".name",
                  "row": {
                    "type": "row", "gap": 10, "width": "fill", "style": { "size": 12 },
                    "vars": { "n": ".name" },
                    "children": [
                      { "type": "text", "text": "{{ .name }}", "lines": 1, "width": { "expr": "$nameWidth" }, "style": { "font": "mono" } },
                      { "type": "text", "text": "{{ .text }}", "lines": 1, "width": "fill",
                        "style": { "color": { "expr": "{up: \"good\", starting: \"accent\", unhealthy: \"warn\", restarting: \"warn\", paused: \"warn\", failed: \"bad\"}[.kind] // \"subtle\"" } } },
                      { "type": "row", "gap": 10, "when": "$stats", "loading": "show",
                        "source": { "type": "dockerStats", "program": { "param": "program" }, "host": { "param": "host" } },
                        "style": { "font": "mono", "color": "subtle" },
                        "children": [
                          { "type": "text", "width": 44, "align": "end",
                            "text": "{{ ([.[]? | select(.name == $n)] | first | .cpu) as $c | if $c == null then \"–\" else ($c | fmt_fixed(0)) + \"%\" end }}" },
                          { "type": "text", "width": 62, "align": "end",
                            "text": "{{ ([.[]? | select(.name == $n)] | first | .mem) as $m | if $m == null then \"–\" else ($m | fmt_bytes) end }}" }
                        ] }
                    ] } },
                { "type": "text", "when": "$hidden > 0", "text": "+ {{ $hidden }} more", "style": { "size": 11, "color": "dim" } }
              ]
            }
          },

          "tailnet": {
            "description": "Your Tailscale devices: online state, address and roles such as exit node and subnet router",
            "params": {
              "program": { "type": "string", "default": "tailscale", "description": "The CLI; on macOS with the app, /Applications/Tailscale.app/Contents/MacOS/Tailscale" },
              "showOffline": { "type": "boolean", "default": true, "description": "Also list devices that are offline (dimmed, after the online ones)" },
              "limit": { "type": "integer", "default": 12, "description": "Devices shown" }
            },
            "widget": {
              "type": "stack", "gap": 8, "width": "fill",
              "source": { "type": "tailscaleStatus", "program": { "param": "program" } },
              "input": "if type == \"object\" then . else {} end",
              "vars": {
                "devices": "(.devices | if type == \"array\" then . else [] end) | map(select(type == \"object\" and ($showOffline or .online))) | .[:$limit]",
                "nameWidth": "[60, ((($devices | map(.name | length) | max) // 0) * 8.6 | ceil), 180] | sort | .[1]"
              },
              "children": [
                { "type": "text", "when": ".state != null and .state != \"Running\"", "text": "Tailscale is {{ .state | ascii_downcase }}", "style": { "size": 12, "color": "subtle" } },
                { "type": "list", "gap": 8, "width": "fill", "items": "$devices", "rowId": ".name",
                  "row": {
                    "type": "row", "gap": 10, "width": "fill",
                    "vars": {
                      "status": "if .self then \"this device\" elif .online then (if .active then \"active\" elif .since != null then \"idle \" + ((now - .since) | fmt_duration(1)) else \"idle\" end) elif .lastSeen != null then \"last seen \" + ((now - .lastSeen) | fmt_duration(1)) else \"offline\" end"
                    },
                    "children": [
                      { "type": "icon", "name": "circle", "weight": "fill", "size": 7, "color": { "expr": "if .online then \"good\" else \"dim\" end" } },
                      { "type": "text", "text": "{{ .name }}", "lines": 1, "width": { "expr": "$nameWidth" },
                        "style": { "size": 13, "weight": "semibold", "font": "mono", "color": { "expr": "if .online then \"text\" else \"subtle\" end" } } },
                      { "type": "text", "text": "{{ .ip }}", "width": 100,
                        "style": { "size": 12, "font": "mono", "color": { "expr": "if .online then \"subtle\" else \"dim\" end" } } },
                      { "type": "text", "text": "{{ $status }}", "lines": 1, "style": { "size": 11, "color": "dim" } },
                      { "type": "spacer" },
                      { "type": "badge", "when": ".exitNode or .usingExit", "text": "{{ if .usingExit then \"exit node in use\" else \"exit node\" end }}", "color": "purple" },
                      { "type": "badge", "when": ".subnet", "text": "subnet", "color": "accent" },
                      { "type": "badge", "when": ".expired", "text": "key expired", "color": "warn" }
                    ] } }
              ]
            }
          },

          "uptimeMonitors": {
            "description": "Status dots, 45 bars of history, uptime and the latest incident for each monitored service (an uptimeKuma or healthchecks source)",
            "params": {
              "limit": { "type": "integer", "default": 12, "description": "Services shown" },
              "warnBelow": { "type": "number", "default": 99.5, "description": "A service whose uptime is under this percent gets a yellow dot" }
            },
            "widget": {
              "type": "stack", "gap": 9, "width": "fill",
              "input": "if type == \"object\" then . + {services: ((.services | if type == \"array\" then . else [] end) | map(select(type == \"object\")))} else {services: []} end",
              "vars": {
                "notice": ".notice",
                "nameWidth": "[84, ((((.services // []) | map(.name | length) | max) // 0) * 7.2 | ceil), 170] | sort | .[1]",
                "inc": "[(.services // [])[] | select(.incident != null) | .incident + {name: .name}] | sort_by(.at) | last",
                "mins": "if $inc == null or $inc.seconds == null then null else ($inc.seconds / 60 | round) end",
                "dur": "if $mins == null then \"\" elif $mins < 120 then \" \\($mins) min\" else \" \" + ($inc.seconds | fmt_duration(2)) end",
                "line": "if $notice != null then $notice.text elif $inc == null then null else $inc.name + \": \" + $inc.status + (if $mins == null then \" since\" else $dur + \",\" end) + \" \" + ($inc.at | fmt_time(\"EEEE HH:mm\")) end"
              },
              "children": [
                { "type": "list", "gap": 9, "width": "fill", "items": ".services", "limit": { "param": "limit" }, "rowId": ".name",
                  "row": {
                    "type": "row", "gap": 10, "width": "fill",
                    "children": [
                      { "type": "icon", "name": "circle", "weight": "fill", "size": 7,
                        "color": { "expr": "if .state == \"down\" then \"bad\" elif .state == \"degraded\" or .state == \"maintenance\" or (.uptime != null and .uptime < $warnBelow) then \"warn\" elif .state == \"up\" then \"good\" else \"dim\" end" } },
                      { "type": "text", "text": "{{ .name }}", "lines": 1, "width": { "expr": "$nameWidth" } },
                      { "type": "bars", "when": ".days != null", "width": "fill", "height": 16, "gap": 2, "max": 1,
                        "values": ".days | map({value: 1, color: ({good: \"good@0.7\", warn: \"warn\", bad: \"bad\", none: \"track\"}[.] // \"track\")})" },
                      { "type": "text", "when": ".days == null", "width": "fill", "lines": 1,
                        "text": "{{ if .state == \"paused\" then \"paused\" elif .lastPing == null then \"never pinged\" else \"pinged \" + (.lastPing | fmt_relative) end }}",
                        "style": { "size": 11, "color": "dim" } },
                      { "type": "text", "when": ".uptime != null", "text": "{{ .uptime | fmt_fixed(2) }}%", "width": 50, "align": "end",
                        "style": { "size": 11, "font": "mono" } }
                    ] } },
                { "type": "row", "gap": 8, "width": "fill", "when": "$line != null or .window != null", "style": { "size": 11 },
                  "children": [
                    { "type": "icon", "name": "warning", "size": 11, "color": "warn", "when": "$line != null" },
                    { "type": "text", "text": "{{ $line }}", "lines": 1, "when": "$line != null", "style": { "color": "subtle" } },
                    { "type": "spacer" },
                    { "type": "text", "text": "{{ .window }}", "when": ".window != null", "style": { "color": "dim" } }
                  ] }
              ]
            }
          },

          "backups": {
            "description": "Last run, result and next run of each backup job, from a directory of small JSON status files; failures say why",
            "params": {
              "dir": { "type": "string", "default": "~/.local/state/vestal/backups", "description": "The directory of status files, one .json per job" },
              "expectEvery": { "type": "string", "default": "1d", "description": "A job that has not run for longer than this is late (\"26h\", \"1d\", \"7d\"); a file's own expectEvery wins" },
              "limit": { "type": "integer", "default": 8, "description": "Jobs shown, failed ones first" }
            },
            "widget": {
              "type": "stack", "gap": 9, "width": "fill",
              "source": { "type": "file", "path": { "param": "dir" }, "refresh": "30s", "when": "visible" },
              "vars": {
                "jobs": "\#(jq(secondsDef)) (if type == \"array\" then map(select(type == \"object\")) else [] end) | map(((.lastRun // ._modified) | try to_epoch catch null) as $last | ((.expectEvery // $expectEvery) | secs) as $every | (.ok != false) as $ok | . + {last: $last, good: $ok, late: ($last == null or ($every != null and (now - $last) > $every)), over: (if $last != null and $every != null then now - $last - $every else null end)}) | map(. + {rank: (if .good | not then 0 elif .late then 1 else 2 end), label: (.name // ._file // \"job\")}) | sort_by([.rank, (.label | ascii_downcase)]) | .[:$limit]"
              },
              "children": [
                { "type": "list", "gap": 9, "width": "fill", "items": "$jobs", "rowId": ".label",
                  "row": {
                    "type": "row", "gap": 10, "width": "fill",
                    "vars": {
                      "c": "if .rank == 0 then \"bad\" elif .rank == 1 then \"warn\" else \"good\" end",
                      "ago": "if .last == null then \"never run\" else (now - .last) as $s | if $s < 60 then \"just now\" elif $s < 3600 then \"\\($s / 60 | floor) min ago\" elif $s < 172800 then \"\\($s / 3600 | floor)h ago\" else \"\\($s / 86400 | floor)d ago\" end end",
                      "size": "if .size == null then null elif (.size | type) == \"number\" then (.size | fmt_bytes) else (.size | tostring) end",
                      "line": "[(if .rank == 0 then \"failed \" + $ago else $ago end), (if .rank == 1 and .over != null then \"late by \" + (.over | fmt_duration(1)) else null end), .message, (if .rank == 2 then $size else null end)] | map(select(. != null and . != \"\")) | join(\" · \")",
                      "next": "(.next // null) | if . == null then null elif type == \"number\" then (if . > now then \"next \" + (if . - now < 86400 then (. | fmt_time(\"HH:mm\")) else (. | fmt_time(\"EEE HH:mm\")) end) else null end) else tostring end"
                    },
                    "children": [
                      { "type": "icon", "size": 13, "width": 16, "color": { "expr": "$c" },
                        "name": { "expr": "{bad: \"x-circle\", warn: \"warning\", good: \"check-circle\"}[$c]" } },
                      { "type": "stack", "gap": 2, "width": "fill", "align": "start", "children": [
                        { "type": "row", "gap": 8, "align": "baseline", "children": [
                          { "type": "text", "text": "{{ .label }}", "style": { "weight": "medium" } },
                          { "type": "text", "text": "{{ .tool }}", "when": ".tool != null", "style": { "size": 10.5, "font": "mono", "color": "dim" } }
                        ] },
                        { "type": "text", "text": "{{ $line }}", "lines": 1, "style": { "size": 11, "color": { "expr": "if $c == \"good\" then \"subtle\" else $c end" } } }
                      ] },
                      { "type": "text", "text": "{{ $next }}", "when": "$next != null", "style": { "size": 11, "font": "mono", "color": "dim" } }
                    ] } }
              ]
            }
          },

          "transfers": {
            "description": "Downloads and long jobs with a bar, speed and time left (an aria2 source, or any list of {name, percent, detail, right})",
            "params": {
              "limit": { "type": "integer", "default": 6, "description": "Transfers shown" }
            },
            "widget": {
              "type": "list", "gap": 10, "width": "fill", "items": "if type == \"array\" then map(select(type == \"object\")) else [] end", "limit": { "param": "limit" }, "rowId": ".name",
              "row": {
                "type": "stack", "gap": 5, "width": "fill",
                "vars": { "c": ".color // (if .percent != null and .percent >= 100 then \"good\" else \"accent\" end)" },
                "children": [
                  { "type": "row", "gap": 8, "width": "fill", "children": [
                    { "type": "icon", "name": { "expr": ".icon // \"download\"" }, "size": 12, "color": { "expr": "$c" } },
                    { "type": "text", "text": "{{ .name }}", "lines": 1, "width": "fill", "style": { "size": 12, "font": "mono" } },
                    { "type": "text", "when": ".percent != null", "text": "{{ .percent | round }}%", "style": { "size": 11, "font": "mono", "color": "subtle" } }
                  ] },
                  { "type": "progress", "value": ".percent // 0", "height": 4, "text": "", "color": { "expr": "$c" } },
                  { "type": "row", "gap": 8, "width": "fill", "when": "(.detail // \"\") != \"\" or (.right // \"\") != \"\"", "style": { "size": 11, "color": "dim" }, "children": [
                    { "type": "text", "text": "{{ .detail }}" },
                    { "type": "spacer" },
                    { "type": "text", "text": "{{ .right }}" }
                  ] }
                ] } }
          }
        }
        """#
    }

    /// `labJSON`, parsed.
    public static let labTree: AnyJSON = {
        guard case .success(let tree) = AnyJSON.parse(Data(labJSON.utf8)) else { return .object([:]) }
        return tree
    }()

    /// The source templates of this file: data packs, which have no sample of their own.
    static let labSources: Set<String> = ["dockerPs", "dockerStats", "tailscaleStatus", "uptimeKuma", "healthchecks", "aria2"]
}
