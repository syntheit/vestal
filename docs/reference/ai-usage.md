# AI plan usage

vestal can show how much of a Claude or Codex plan's rate limits you have used: the 5-hour window and the weekly one, with when each resets. The numbers are the services' own (what Claude Code's `/usage` and Codex's `/status` show), not estimates. Codex's come from `codex app-server`, which keeps its own login; vestal reads none of it. Claude's come from Anthropic's usage endpoint with Claude Code's access token (read only), or from `claude -p /usage`.

## Claude

The `claude` source has two backends, chosen by `backend` (`auto`, `api` or `cli`; default `auto`).

The API backend makes one `GET https://api.anthropic.com/api/oauth/usage`, the same request as Claude Code's `/usage`, with the access token of Claude Code's login. It takes a fraction of a second and starts no other program. The token is read from `.credentials.json` in `$CLAUDE_CONFIG_DIR` (default `~/.claude`) or, on macOS, from the login keychain item `Claude Code-credentials` when the file has no valid token. vestal only reads it: it never refreshes or writes it, never logs or shows it, and sends it to `api.anthropic.com` only. `five_hour` is `session`, `seven_day` is `weekly`, and the per-model windows (Claude Code's own names, such as `Fable`) are `extra`. The endpoint is not documented by Anthropic, so it may change.

The CLI backend runs `claude -p --no-session-persistence /usage`. Claude Code prints the account's plan usage, the same numbers as `/usage` in a session, without a model call, and exits within a few seconds:

```
Current session: 25% used · resets Sep 27 at 7:10pm (America/Buenos_Aires)
Current week (all models): 59% used · resets Oct 3 at 7pm (America/Buenos_Aires)
Current week (Fable): 0% used · resets Oct 3 at 7pm (America/Buenos_Aires)
```

vestal reads those lines: `Current session` is `session`, `Current week (all models)` is `weekly`, and any other `Current week (<name>)` goes to `extra` with that name as its `label`. A reset time is read in the zone in parentheses (`Sep 27 at 7:10pm`, `Oct 3, 7pm`, `7:10pm`, `in 3h 20m`); one vestal can't read keeps its text in `resetsText` with `resetsAt` null. Color codes, notices and the rest of the output are ignored.

Claude Code uses its own login (Pro or Max). The command runs in vestal's cache directory (`~/Library/Caches/Vestal` on macOS, `$XDG_CACHE_HOME/vestal` or `~/.cache/vestal` on Linux), and `--no-session-persistence` keeps it from writing a transcript at every refresh (vestal drops the flag for a Claude Code too old to know it). It refreshes every 5 minutes while the dashboard is shown, and when you show the dashboard with data older than a minute. `vestal fetch claude` runs it and shows the data. vestal looks for `claude` on `PATH`, in the Nix and Homebrew directories and in `~/.local/bin` (Claude Code's native installer); anywhere else, set `"argv": ["~/.local/bin/claude", "-p", "--no-session-persistence", "/usage"]` on the source.

A status line is unnecessary. Earlier versions read Claude's numbers from Claude Code's `statusLine` input, which gives session numbers instead of account numbers. `vestal claude-statusline` still works as a status line that shows the `claude` source's cached numbers (`5h 25% · wk 59%`, nothing before the first fetch), with `--then <command>` to chain another one; it writes nothing. Under Home Manager, `programs.vestal.claudeStatusLine.enable` (off by default) sets it up; while it is off, activation removes a `statusLine` from `~/.claude/settings.json` only when it is exactly vestal's own (`/nix/store/…/bin/vestal claude-statusline`), leaves one that chains another command with a warning, and touches nothing else. A status line you set by hand stays until you remove it.

## Codex

The `codex` source runs `codex app-server`, asks for the rate limits over JSON-RPC (`initialize`, then `account/rateLimits/read`) and stops it as soon as it answers, within 15 seconds. Codex uses its own login (`codex login`); vestal reads nothing of it. It refreshes every 5 minutes while the dashboard is shown, and when you show the dashboard with data older than a minute. `vestal fetch codex` shows the data. If `codex` isn't on the dashboard's `PATH`, set `"argv": ["/path/to/codex", "app-server"]` on the source.

Codex reports up to two windows; vestal places them by length (up to a day: `session`, longer: `weekly`). Some plans have only a weekly one, so `session` is `null`.

## The data

Both sources give the same shape:

```jsonc
{
  "session": { "percent": 25, "resetsAt": 1790547000,     // the 5-hour window, or null
               "resetsText": "Sep 27 at 7:10pm (America/Buenos_Aires)" },
  "weekly": { "percent": 59, "resetsAt": 1791064800,      // the weekly window (all models), or null
              "resetsText": "Oct 3 at 7pm (America/Buenos_Aires)" },
  "extra": [                                              // claude's per-model weekly windows
    { "label": "Fable", "percent": 0, "resetsAt": 1791064800, "resetsText": "Oct 3 at 7pm (America/Buenos_Aires)" }
  ],
  "updatedAt": 1790528602,                                // epoch seconds
  "source": "cli",                                        // "api" or "cli" (claude), or "codex"
  "plan": null                                            // Codex: the plan's name
}
```

`percent` is a whole number 0-100, `resetsAt` epoch seconds. `resetsText` is the reset as Claude Code wrote it (`null` for Codex); `extra` is empty for Codex. A window whose reset time has passed reads `{"percent": 0, "resetsAt": null}` until the next fetch.

## Showing it

- `aiUsage`: one row with Claude's and Codex's windows as small bars, a percentage each and `in 4h` after it, all on one line. A service without data yet is left out. `{"type": "aiUsage"}`; `show: ["codex"]` for one service.
- `aiPlan`: the same windows as full-width bars, one per window (5 hours, week, and a `<model> week` for each of Claude's per-model windows) with the percentage and when it resets. The weekly bars carry a white tick where usage would be at an even pace through the week (the elapsed share of the 7-day window, found from `resetsAt`). The plan badge is Codex's `plan`; Claude's endpoint doesn't give one, so write `"claudePlan": "Max"`. `{"type": "aiPlan"}`; `show: ["codex"]` for one service.
- System bar items: `"claudeUsage"` and `"codexUsage"` in a `systemBar`'s `show` draw `session% / weekly%` with an icon. `codexUsage` is only drawn when listed.
- `claudeUsage`: the Claude item as a row of its own.
- Your own: any widget over the sources, such as `{ "type": "progress", "source": "claude", "label": "Claude", "value": ".weekly.percent // 0" }`, `{{ .weekly.resetsAt - now | fmt_duration(1) }}` for the time left, or a `list` over `.extra` for the per-model limits.

## When it shows nothing

- `vestal fetch claude` says `claude not found` (the cli backend, or auto with no valid token): set `argv` (see above). `source` in the data says which backend answered; `"backend": "cli"` skips the endpoint, and `vestal capabilities` shows which one will be used. `not logged in`: run `claude` and `/login`. `shows no plan usage`: Claude Code is logged in with an API key, not a Pro or Max subscription.
- `vestal fetch codex` says `codex not found`: set `argv`. An error from `codex app-server` usually means `codex login` is needed.
- `vestal capabilities` lists both sources and whether their programs are found.
- The old `path`, `fiveHourLimit` and `weeklyLimit` on a `claude` source or `claudeUsage` widget are ignored now (an info finding says so); remove them.
