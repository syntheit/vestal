# AI plan usage

vestal can show how much of a Claude or Codex plan's rate limits you have used: the 5-hour window and the weekly one, with when each resets. The numbers are the services' own (what claude.ai's usage page and Codex's `/status` show), not estimates. vestal never reads a credential, a token or the Keychain for them, and makes no request of its own to Anthropic or OpenAI.

## Claude

Claude Code (2.1.80 or later) passes the plan's rate limits to its status line command, for Pro and Max plans. `vestal claude-statusline` is such a command: it keeps the two windows for the `claude` source and prints a short line for Claude Code to show, `5h 35% · wk 50%`.

Set it up once, either way:

- Home Manager: `programs.vestal.claudeStatusLine.enable = true;`. Activation adds the `statusLine` to `~/.claude/settings.json` when it has none (the file stays Claude Code's, never a link), updates it after a vestal update, and leaves any other status line alone with a warning.
- By hand, in `~/.claude/settings.json`:

```jsonc
{ "statusLine": { "type": "command", "command": "vestal claude-statusline" } }
```

Already have a status line? Chain it: `vestal claude-statusline --then ~/.claude/statusline.sh` prints vestal's part, then that command's output, which gets the same input. One word after `--then` runs through `/bin/sh -c`, so a quoted command line works (`--then 'npx ccusage statusline'`); several words run as they are.

What it keeps: `rate_limits.five_hour` and `rate_limits.seven_day` (`used_percentage`, `resets_at`) and the time, in `claude-rate-limits.json` in the cache directory (`~/Library/Caches/Vestal` on macOS, `$XDG_CACHE_HOME/vestal` or `~/.cache/vestal` on Linux), mode 0600, written atomically. Nothing else of Claude Code's input (model, directory, session) is stored. Input without rate limits (before the session's first answer, or an API-key login) prints nothing of vestal's and stores nothing; a window Claude Code leaves out (it drops one once it resets) keeps the stored one. It never fails loudly: bad input prints nothing and exits 0.

Then `vestal fetch claude` shows the data. The numbers are as fresh as Claude Code's last status line update, which comes after each response: `updatedAt` says when. A window whose reset time has passed reads 0% with an unknown reset until Claude Code reports again.

## Codex

The `codex` source runs `codex app-server`, asks for the rate limits over JSON-RPC (`initialize`, then `account/rateLimits/read`) and stops it as soon as it answers, within 15 seconds. Codex uses its own login (`codex login`); vestal reads nothing of it. It refreshes every 5 minutes while the dashboard is shown, and when you show the dashboard with data older than a minute. `vestal fetch codex` shows the data. If `codex` isn't on the dashboard's `PATH`, set `"argv": ["/path/to/codex", "app-server"]` on the source.

Codex reports up to two windows; vestal places them by length (up to a day: `session`, longer: `weekly`). Some plans have only a weekly one, so `session` is `null`.

## The data

Both sources give the same shape:

```jsonc
{
  "session": { "percent": 35, "resetsAt": 1790546843 },  // the 5-hour window, or null
  "weekly": { "percent": 50, "resetsAt": 1790831843 },   // the 7-day window, or null
  "updatedAt": 1790531843,                                // epoch seconds
  "source": "claude",                                     // or "codex"
  "plan": null                                            // Codex: the plan's name
}
```

## Showing it

- **`aiUsage`**: one row with Claude's and Codex's windows as small bars, a percentage each and `resets 4h` under it. A service without data yet is left out. `{"type": "aiUsage"}`; `show: ["codex"]` for one service.
- **System bar items**: `"claudeUsage"` and `"codexUsage"` in a `systemBar`'s `show` draw `session% / weekly%` with an icon. `codexUsage` is only drawn when listed.
- **`claudeUsage`**: the Claude item as a row of its own.
- **Your own**: any widget over the sources, such as `{ "type": "progress", "source": "claude", "label": "Claude", "value": ".weekly.percent // 0" }`, or `{{ .weekly.resetsAt - now | fmt_duration(1) }}` for the time left.

## When it shows nothing

- `vestal fetch claude` says `no Claude usage yet`: the status line isn't set up, or Claude Code hasn't answered in a session since (Pro and Max plans only). Run `vestal claude-statusline < /dev/null` to check the command is found where Claude Code runs it.
- On Linux, Claude Code and vestal must agree on `XDG_CACHE_HOME` (or both leave it unset).
- `vestal fetch codex` says `codex not found`: set `argv`. An error from `codex app-server` usually means `codex login` is needed.
- `vestal capabilities` lists both sources and whether they can work here.
- v0.3's `path`, `fiveHourLimit` and `weeklyLimit` on a `claude` source or `claudeUsage` widget are ignored now (an info finding says so); remove them.
