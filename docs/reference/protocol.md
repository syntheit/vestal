# The subscribe protocol

A UI in any language or toolkit can draw vestal: it connects to the running instance's socket, subscribes, and receives the render model (`vestal docs render-model`) as a stream of JSON lines. `vestal subscribe` is the reference client and a debugging tool:

```text
vestal subscribe [--view <name>] [--while-hidden] [--role ui|observer] [--control] [--json-only]
```

It prints every message the instance sends, one JSON object per line, until Ctrl-C, and exits 1 when no instance runs.

## The socket

- The instance's unix socket: `$XDG_RUNTIME_DIR/vestal.sock` on Linux (else `/run/user/<uid>/vestal.sock`, else `vestal-<uid>.sock` in the temporary directory); `vestal-<uid>.sock` in the per-user temporary directory on macOS. The instance logs the path when it starts.
- Only the owner's processes get in: the socket is `0600` and both ends check the peer's uid.
- A request is one line. A line starting with `{` is JSON, `{"cmd": "<name>", …}`; bare words (`toggle`, `status`, …) still work. One-shot requests (`toggle`, `show`, `hide`, `reload`, `status`, `quit`, `sources`, `fetch`, `render`, `eval`) get one reply line and the connection closes.

## Subscribing

```jsonc
{"cmd": "subscribe", "role": "ui", "protocol": [1], "minor": 0, "client": "my-ui/0.1", "capabilities": ["copy", "notify"], "whileHidden": false, "control": false, "view": null}
```

| Field | Default | |
|---|---|---|
| `role` | `observer` | `ui` draws the dashboard; `observer` watches (status bars, debuggers). |
| `protocol` | `[1]` | The major versions the client speaks. Without `1`: an `error` message, and the connection closes. |
| `minor` | `0` | The minor version the client understands; newer node types come as `text` with their `alt`. |
| `client` | none | A name for logs. |
| `capabilities` | `[]` | What a `ui` can do: `copy` (set the clipboard), `notify` (show a transient message). |
| `whileHidden` | `false` | Keep evaluating and sending patches while the dashboard is hidden (debugging). |
| `control` | `false` | Let an observer's `invoke`, `key`, `hide` and `view` count. |
| `view` | none | Switch to this view. |

The connection then stays open. The server writes one JSON message per line; the client writes commands, one per line.

## Server messages

| Message | |
|---|---|
| `{"type": "hello", "protocol": 1, "minor": 0, "server": "0.4.0 (abc1234)", "os": "linux", "role": "observer", "primary": false}` | First, after `subscribe`. `primary` says whether this subscriber is the primary UI. |
| `snapshot` | The whole model (`vestal docs render-model`), with this connection's `seq`. |
| `patch` | Changes since `base` (`vestal docs render-model`). At most one per 50 ms per subscriber; a patch bigger than half a snapshot is sent as a snapshot. |
| `{"type": "visibility", "visible": true, "view": "main"}` | Show or hide the window. The core decides: `vestal toggle`, Escape and actions all go through it. |
| `{"type": "effect", "effect": "copy", "text": "…"}` | Put the text on the clipboard. |
| `{"type": "effect", "effect": "notify", "level": "error", "text": "…"}` | An optional transient message, such as a failed `run`. |
| `{"type": "error", "code": "protocol", "message": "…", "supported": [1]}` | Then the connection closes. |

While the dashboard is hidden nothing is evaluated and no patches are sent (unless a subscriber set `whileHidden`). On show, every subscriber gets a fresh snapshot, then `visibility`.

## Client commands

| Command | When |
|---|---|
| `{"cmd": "invoke", "id": "<node id>"}` | A click on a node with `action: true`. |
| `{"cmd": "key", "key": "h"}` | Every key press the UI doesn't handle itself, in the key grammar (`"shift+tab"`, `"escape"`). The core decides what it means, Escape included. |
| `{"cmd": "hide"}` | The window went away on its own. |
| `{"cmd": "view", "name": "focus"}` | A switcher in the UI. |
| `{"cmd": "snapshot"}` | Resync: a patch's `base` didn't match. |

## Roles

- The **primary UI** is the most recent `ui` subscriber still connected. When it disconnects, the previous `ui` subscriber becomes primary.
- Only the primary UI receives effects, and only its `invoke`, `key`, `hide` and `view` count.
- Observers get snapshots, patches and visibility; their commands are ignored unless they subscribed with `control: true`. `snapshot` always works.

## Backpressure

The server never waits for a client. Each connection has its own outbound queue; a client that falls more than 4 MiB behind is disconnected and should reconnect and subscribe again (it gets a fresh snapshot).

## Writing a UI

A conforming UI:

1. subscribes with `role: "ui"` and applies `snapshot` and `patch` (asking for a `snapshot` when a `base` doesn't match);
2. maps and unmaps its window on `visibility` (on Wayland: a layer-shell surface, namespace `vestal`, exclusive keyboard while shown);
3. draws every node type and field of `vestal docs render-model`, with the icon fonts of `vestal docs icons`;
4. sends `invoke` for clicks on `action` nodes and `key` for key presses, and carries out `copy` effects.

The GTK UI inside vestal on Linux, and the SwiftUI UI on macOS, draw the same model in-process.
