import Foundation

// MARK: - Developer presets
//
// `reviewQueue`, `ciStatus`, `commitActivity` and `flakeInputs`, and the
// `github` source template the first two (and `flakeInputs` with `behind`)
// share: one definition of the endpoint, the headers and the token, so a
// config names the token once (the `github` secret, `gh auth token` unless
// the config defines one). Like every built-in template they are written in
// the public config language.
//
// Data shapes. `github` sources hand the GraphQL answer to a `transform`
// written by the preset; the widgets read what the transform makes:
//   reviewQueue     [ {repo, nameWithOwner, number, title, url, additions, deletions,
//                      author, created, draft, state} ], newest first
//   ciStatus        [ {repo, nameWithOwner, branch, url, runs, state, started, finished} ]
//   commitActivity  {days: {"<days since 1970-01-01>": commits}}
//   flakeInputs     the `flake` source's data (FlakeInputs)

extension DefaultPresets {
    /// The templates, name → definition.
    static let devJSON = #"""
    {
      "github": {
        "description": "GitHub's GraphQL API with the token of the `github` secret (`gh auth token` unless you define that secret)",
        "params": {
          "query": { "type": "string", "default": "", "description": "A GraphQL document" },
          "variables": { "type": "object", "default": {}, "description": "Its variables" },
          "body": { "type": "string", "default": "", "description": "A complete request body ({\"query\": …, \"variables\": …} as JSON text) instead of query and variables, for queries a preset builds from its parameters" }
        },
        "source": {
          "type": "http",
          "url": "https://api.github.com/graphql",
          "method": "POST",
          "headers": {
            "Authorization": "Bearer {{ $secrets.github }}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json"
          },
          "body": "{{ if $body != \"\" then $body else ({query: $query, variables: $variables} | tojson) end }}",
          "refresh": "5m",
          "when": "visible",
          "timeout": "20s"
        }
      },

      "reviewQueue": {
        "description": "Pull requests waiting on your review, newest first: repository and number, title, size, author and age, with a summary",
        "params": {
          "search": { "type": "string", "default": "is:pr is:open review-requested:@me archived:false", "description": "A GitHub issue search; every pull request it finds is listed" },
          "limit": { "type": "integer", "default": 5, "description": "Rows shown" },
          "refresh": { "type": "duration", "default": "5m", "description": "Five minutes keeps well inside GitHub's rate limits" },
          "numberKeys": { "type": "boolean", "default": true, "description": "Keys 1 to 9 open the pull requests of the rows" }
        },
        "widget": {
          "type": "stack", "gap": 9, "width": "fill", "align": "start",
          "source": {
            "type": "github",
            "query": "query($q: String!) { search(query: $q, type: ISSUE, first: 30) { nodes { ... on PullRequest { number title url additions deletions createdAt isDraft reviewDecision author { login } repository { name nameWithOwner } } } } }",
            "variables": { "q": { "param": "search" } },
            "transform": "if (.data.search // null) == null then error(.errors[0].message // \"GitHub returned no data\") else .data.search.nodes | map(select(.number != null)) | map({repo: .repository.name, nameWithOwner: .repository.nameWithOwner, number, title, url, additions: (.additions // 0), deletions: (.deletions // 0), author: (.author.login // \"ghost\"), created: (.createdAt | to_epoch), draft: (.isDraft // false), state: (if .isDraft then \"draft\" elif .reviewDecision == \"APPROVED\" then \"approved\" elif .reviewDecision == \"CHANGES_REQUESTED\" then \"changes\" else \"review\" end)}) | sort_by(.created) | reverse end",
            "refresh": { "param": "refresh" }
          },
          "children": [
            {
              "type": "list", "gap": 9, "width": "fill",
              "vars": {
                "idWidth": "[((map(.repo + \"#\" + (.number | tostring) | length) | max) // 0) * 7.2 | ceil, 40] | max",
                "authorWidth": "[((map(.author | length) | max) // 0) * 6.6 | ceil + 8, 30] | max"
              },
              "items": ".", "limit": { "param": "limit" }, "rowId": ".url",
              "row": {
                "type": "row", "gap": 10, "width": "fill",
                "action": { "open": "{{ .url }}" },
                "key": { "expr": "if $numberKeys then $index + 1 | tostring else null end" },
                "keyHint": "{{ .title }}",
                "children": [
                  { "type": "icon", "name": "git-pull-request", "size": 12,
                    "color": { "expr": "{review: \"accent\", changes: \"warn\", approved: \"good\", draft: \"dim\"}[.state] // \"accent\"" } },
                  { "type": "text", "text": "{{ .repo }}#{{ .number }}", "lines": 1, "minWidth": { "expr": "$idWidth" },
                    "style": { "size": 11, "font": "mono", "color": "dim" } },
                  { "type": "text", "text": "{{ .title }}", "lines": 1, "width": "fill", "style": { "weight": "medium" } },
                  { "type": "text", "text": "+{{ .additions }}", "style": { "size": 10, "font": "mono", "color": "good" } },
                  { "type": "text", "text": "−{{ .deletions }}", "style": { "size": 10, "font": "mono", "color": "bad" } },
                  { "type": "text", "text": "@{{ .author }}", "lines": 1, "minWidth": { "expr": "$authorWidth" },
                    "style": { "size": 11, "color": "subtle" } },
                  { "type": "text", "text": "{{ now - .created | fmt_duration(1) }}", "lines": 1, "minWidth": 26, "align": "end",
                    "style": { "size": 11, "font": "mono", "color": "dim" } }
                ]
              }
            },
            { "type": "row", "gap": 8, "when": "length > 0", "children": [
              { "type": "badge", "text": "{{ length }} waiting on you", "color": "accent" },
              { "type": "text", "text": "oldest {{ now - (map(.created) | min) | fmt_duration(1) }}", "style": { "size": 11, "color": "dim" } }
            ] },
            { "type": "row", "gap": 6, "when": "length == 0", "children": [
              { "type": "icon", "name": "check-circle", "size": 12, "color": "good" },
              { "type": "text", "text": "No reviews waiting on you", "style": { "size": 12, "color": "subtle" } }
            ] }
          ]
        }
      },

      "ciStatus": {
        "description": "The latest GitHub Actions results per repository and branch: a state icon, the last results as coloured cells and how long the newest took",
        "params": {
          "repos": { "type": "array", "required": true, "description": "[\"owner/name\", \"owner/name@branch\"]: a repository, on its default branch unless a branch follows the @" },
          "runs": { "type": "integer", "default": 12, "description": "Cells per repository, at most 30" },
          "refresh": { "type": "duration", "default": "5m" }
        },
        "widget": {
          "type": "list", "gap": 9, "width": "fill",
          "source": {
            "type": "github",
            "body": "{{ {query: (\"query { \" + ($repos | map(select(type == \"string\" and contains(\"/\"))) | to_entries | map(.key as $i | (.value | split(\"@\")) as $p | ($p[0] | split(\"/\")) as $r | \"r\" + ($i | tostring) + \": repository(owner: \" + ($r[0] | tojson) + \", name: \" + ($r[1] | tojson) + \") { name nameWithOwner \" + (if $p[1] then \"ref(qualifiedName: \" + ($p[1] | tojson) + \")\" else \"defaultBranchRef\" end) + \" { name target { ... on Commit { history(first: 30) { nodes { oid committedDate checkSuites(first: 10, filterBy: {appId: 15368}) { nodes { status conclusion createdAt updatedAt } } } } } } } }\") | join(\" \")) + \" }\")} | tojson }}",
            "transform": "if .data == null then error(.errors[0].message // \"GitHub returned no data\") else .data | to_entries | sort_by(.key | ltrimstr(\"r\") | tonumber) | map(.value | select(. != null)) | map((.defaultBranchRef // .ref) as $b | select($b != null) | ($b.target.history.nodes // [] | map(([.checkSuites.nodes[]? | select(.conclusion != \"SKIPPED\" and .conclusion != \"NEUTRAL\" and .conclusion != \"STALE\")]) as $s | {state: (if ($s | length) == 0 then \"none\" elif any($s[]; .status != \"COMPLETED\") then \"running\" elif any($s[]; .conclusion == \"FAILURE\" or .conclusion == \"TIMED_OUT\" or .conclusion == \"STARTUP_FAILURE\" or .conclusion == \"ACTION_REQUIRED\") then \"failure\" elif any($s[]; .conclusion == \"CANCELLED\") then \"cancelled\" else \"success\" end), started: ($s | map(.createdAt | to_epoch) | min), finished: ($s | map(.updatedAt | to_epoch) | max)}) | map(select(.state != \"none\")) | .[0:30] | reverse) as $runs | {repo: .name, nameWithOwner, branch: $b.name, url: (\"https://github.com/\" + .nameWithOwner + \"/actions?query=branch%3A\" + ($b.name | @uri)), runs: ($runs | map(.state)), state: (($runs | last | .state) // \"none\"), started: (($runs | last | .started) // null), finished: (($runs | last | .finished) // null)}) end",
            "refresh": { "param": "refresh" }
          },
          "vars": {
            "nameWidth": "[((map(.repo | length) | max) // 0) * 8 | ceil, 36] | max",
            "branchWidth": "[[((map(.branch | length) | max) // 0), 22] | min * 7.6 | ceil, 48] | max"
          },
          "items": ".", "rowId": ".nameWithOwner + \"@\" + .branch",
          "row": {
            "type": "row", "gap": 10, "width": "fill",
            "action": { "open": "{{ .url }}" },
            "vars": { "tone": "{success: \"good\", failure: \"bad\", running: \"warn\", cancelled: \"subtle\"}[.state] // \"dim\"" },
            "children": [
              { "type": "icon", "size": 13, "color": { "expr": "$tone" },
                "name": { "expr": "{success: \"check-circle\", failure: \"x-circle\", running: \"circle-notch\", cancelled: \"minus-circle\"}[.state] // \"circle-dashed\"" } },
              { "type": "text", "text": "{{ .repo }}", "lines": 1, "minWidth": { "expr": "$nameWidth" },
                "style": { "weight": "semibold", "font": "mono" } },
              { "type": "text", "text": "{{ .branch }}", "lines": 1, "minWidth": { "expr": "$branchWidth" }, "maxWidth": 180,
                "style": { "size": 12, "font": "mono", "color": "subtle" } },
              { "type": "list", "direction": "row", "gap": 2,
                "items": "(.runs | length) as $n | (([range([$runs - $n, 0] | max)] | map(\"none\")) + .runs) | .[-$runs:]",
                "row": { "type": "spacer", "width": 6, "height": 14, "radius": 1.5,
                  "background": { "expr": "({success: \"good\", failure: \"bad\", running: \"warn\", cancelled: \"subtle\"}[.] // \"track\") as $c | if . == \"none\" or $index == $runs - 1 then $c else $c + \"@0.5\" end" } } },
              { "type": "spacer" },
              { "type": "text", "lines": 1, "style": { "size": 11, "font": "mono", "color": "dim" },
                "text": "{{ if .state == \"running\" then \"running \" + ((now - .started) | fmt_duration(1)) elif .state == \"none\" then \"no runs\" else (.finished - .started) | fmt_duration(2) end }}" }
            ]
          }
        }
      },

      "commitActivity": {
        "description": "Commits per day across your repositories, as GitHub draws them, with the total and the current streak",
        "params": {
          "paths": { "type": "array", "required": true, "description": "Repository directories; ~/ expands" },
          "weeks": { "type": "integer", "default": 30, "description": "Columns (weeks), the last one the current week" },
          "author": { "type": "string", "default": "", "description": "A git --author pattern; empty: each repository's own user.email" },
          "levels": { "type": "array", "default": [1, 3, 6, 10], "description": "Commits per day from which a cell takes the 1st, 2nd, 3rd and 4th shade" },
          "cell": { "type": "number", "default": 10 },
          "gap": { "type": "number", "default": 3 },
          "refresh": { "type": "duration", "default": "10m" }
        },
        "widget": {
          "type": "stack", "gap": 8, "align": "start",
          "source": {
            "type": "command",
            "argv": [
              "sh", "-c",
              "since=\"$1\"; author=\"$2\"; shift 2; for repo in \"$@\"; do who=\"$author\"; [ -n \"$who\" ] || who=$(git -C \"$repo\" config user.email 2>/dev/null); [ -n \"$who\" ] || continue; git -C \"$repo\" log --branches --since=\"$since\" --format=%cs --author=\"$who\" 2>/dev/null; done; exit 0",
              "vestal", "{{ $weeks + 1 }}.weeks", { "param": "author" }, { "param": "paths" }
            ],
            "parse": "lines",
            "timeout": "30s",
            "when": "visible",
            "refresh": { "param": "refresh" },
            "transform": "{days: (reduce (.[] | select(type == \"string\" and test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}$\"))) as $d ({}; .[($d + \"T00:00:00Z\" | to_epoch / 86400 | floor | tostring)] += 1))}"
          },
          "vars": {
            "today": "now | fmt_time(\"yyyy-MM-dd\") | . + \"T00:00:00Z\" | to_epoch / 86400 | floor",
            "first": "$today - (($today + 4) % 7) - ($weeks - 1) * 7",
            "counts": ".days as $days | [range(0; $weeks * 7)] | map(. + $first | if . > $today then null else ($days[tostring] // 0) end)",
            "total": "$counts | map(. // 0) | add",
            "streak": "$counts | map(select(. != null)) | reverse | if .[0] == 0 then .[1:] else . end | reduce .[] as $c ({n: 0, done: false}; if .done or $c == 0 then .done = true else .n += 1 end) | .n"
          },
          "children": [
            { "type": "heatmap", "cell": { "param": "cell" }, "gap": { "param": "gap" }, "min": 1, "max": 4,
              "scale": ["good@0.28", "good"],
              "values": "$counts | map(if . == null or . == 0 then null else . as $c | [$levels[] | select(. <= $c)] | length end)",
              "alt": "{{ $total }} commits in {{ $weeks }} weeks" },
            { "type": "row", "gap": 12, "width": "fill", "style": { "size": 11 }, "children": [
              { "type": "row", "gap": 4, "children": [
                { "type": "text", "text": "{{ $total | fmt_thousands }}", "style": { "font": "mono", "weight": "medium" } },
                { "type": "text", "text": "commits in {{ $weeks }} weeks", "style": { "color": "subtle" } }
              ] },
              { "type": "row", "gap": 4, "children": [
                { "type": "text", "text": "streak", "style": { "color": "subtle" } },
                { "type": "text", "text": "{{ $streak }}d", "style": { "font": "mono", "weight": "medium", "color": "good" } }
              ] },
              { "type": "spacer" },
              { "type": "row", "gap": 3, "style": { "color": "dim" }, "children": [
                { "type": "text", "text": "less" },
                { "type": "spacer", "width": 9, "height": 9, "radius": 2, "background": "track" },
                { "type": "spacer", "width": 9, "height": 9, "radius": 2, "background": "good@0.28" },
                { "type": "spacer", "width": 9, "height": 9, "radius": 2, "background": "good@0.5" },
                { "type": "spacer", "width": 9, "height": 9, "radius": 2, "background": "good@0.75" },
                { "type": "spacer", "width": 9, "height": 9, "radius": 2, "background": "good" },
                { "type": "text", "text": "more" }
              ] }
            ] }
          ]
        }
      },

      "flakeInputs": {
        "description": "How old each locked input of a Nix flake is, coloured by age, and with behind: true how many commits each GitHub input has gained since",
        "params": {
          "path": { "type": "string", "required": true, "description": "The flake's directory (~/ expands) or flake reference" },
          "behind": { "type": "boolean", "default": false, "description": "Also ask GitHub how many commits each GitHub input's branch is ahead of the lock (one request; uses the `github` secret)" },
          "fresh": { "type": "number", "default": 3, "description": "Days below which a lock is green" },
          "warn": { "type": "number", "default": 14, "description": "Days from which a lock is yellow" },
          "bad": { "type": "number", "default": 30, "description": "Days from which a lock is red" },
          "sort": { "type": "string", "default": "age", "enum": ["age", "name"], "description": "age: the oldest lock first" },
          "limit": { "type": "integer", "default": 8, "description": "Rows shown" },
          "refresh": { "type": "duration", "default": "1h" }
        },
        "widget": {
          "type": "stack", "gap": 9, "width": "fill", "align": "start",
          "source": {
            "type": "flake",
            "path": { "param": "path" },
            "behind": { "param": "behind" },
            "headers": { "Authorization": "Bearer {{ $secrets.github }}", "Content-Type": "application/json" },
            "timeout": "30s",
            "refresh": { "param": "refresh" }
          },
          "vars": {
            "old": ".inputs | map(select(.lastModified != null and (now - .lastModified) / 86400 >= $warn)) | length",
            "updates": ".inputs | map(select((.behind // 0) > 0)) | length"
          },
          "children": [
            { "type": "row", "gap": 10, "width": "fill", "style": { "size": 12 }, "children": [
              { "type": "text", "text": "{{ .path }}", "lines": 1, "style": { "font": "mono", "weight": "semibold" } },
              { "type": "badge", "when": "$behind and $updates > 0", "text": "{{ $updates }} {{ if $updates == 1 then \"update\" else \"updates\" end }}", "color": "warn" },
              { "type": "badge", "when": "$behind and $updates == 0", "text": "up to date", "color": "good" },
              { "type": "badge", "when": "($behind | not) and $old > 0", "text": "{{ $old }} old", "color": "warn" },
              { "type": "badge", "when": "($behind | not) and $old == 0", "text": "all fresh", "color": "good" },
              { "type": "text", "when": "$meta.fetchedAt != null", "text": "checked {{ $meta.fetchedAt | fmt_relative }}", "style": { "color": "dim" } }
            ] },
            { "type": "table", "width": "fill", "when": "$behind", "items": ".inputs", "rowId": ".name", "limit": { "param": "limit" },
              "sortBy": "if $sort == \"name\" then .name else .lastModified end",
              "columns": [
                { "header": "Input", "text": "{{ .name }}", "width": "fill", "style": { "size": 12, "font": "mono" } },
                { "header": "Locked", "value": "now - .lastModified", "format": "duration:1", "align": "end", "width": 80,
                  "style": { "size": 12, "font": "mono" },
                  "color": { "expr": "$value / 86400 | step([[0, \"good\"], [$fresh, \"subtle\"], [$warn, \"warn\"], [$bad, \"bad\"]])" } },
                { "header": "Behind", "align": "end", "width": 110, "style": { "size": 12 },
                  "text": "{{ if .behind == null then \"–\" elif .behind == 0 then \"up to date\" elif .behind == 1 then \"1 commit\" else (.behind | fmt_thousands) + \" commits\" end }}",
                  "color": { "expr": "if .behind == 0 then \"good\" elif .behind == null then \"dim\" else \"subtle\" end" } }
              ] },
            { "type": "table", "width": "fill", "when": "$behind | not", "items": ".inputs", "rowId": ".name", "limit": { "param": "limit" },
              "sortBy": "if $sort == \"name\" then .name else .lastModified end",
              "columns": [
                { "header": "Input", "text": "{{ .name }}", "width": "fill", "style": { "size": 12, "font": "mono" } },
                { "header": "Locked", "value": "now - .lastModified", "format": "duration:1", "align": "end", "width": 80,
                  "style": { "size": 12, "font": "mono" },
                  "color": { "expr": "$value / 86400 | step([[0, \"good\"], [$fresh, \"subtle\"], [$warn, \"warn\"], [$bad, \"bad\"]])" } }
              ] }
          ]
        }
      }
    }
    """#

    static let devTree: AnyJSON = {
        guard case .success(let tree) = AnyJSON.parse(Data(devJSON.utf8)) else { return .object([:]) }
        return tree
    }()
}
