import Foundation

// MARK: - vestal press
//
//   vestal press <key>                   the key goes to the running instance,
//                                        as if typed on the dashboard
//   vestal press <key> --dry-run [--json] [--view <name>] [--press <key>]...
//                [--config <path>|-] [--cached|--fetch|--data <dir>] [--at <time>]
//
// `--dry-run` works here, without an instance: it renders the view (the
// data modes), presses `--press` keys first, then says what the
// key is bound to (popup keys first, then the view) and what the action would do. Nothing
// runs: no `command` source (whatever the config), and no action.
//
// Exit: 0; 1 not running, hidden, or no binding (dry run); 2 usage; 4
// unknown view.

public enum PressCommand {
    public typealias Output = ConfigCommands.Output

    static let usage = """
        usage: vestal press <key>
               vestal press <key> --dry-run [--json] [--view <name>] [--press <key>]... [--config <path>|-]
                                  [--cached|--fetch|--data <dir>] [--at <time>]
        """

    public static func run(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        platform: SourcePlatform,
        client: RenderCommands.Client,
        send: (IPCRequest) throws -> IPCResponse
    ) -> Output {
        var rest: [String] = []
        var key: String?
        var dryRun = false
        var json = false
        var i = 0
        while i < arguments.count {
            let argument = arguments[i]
            switch argument {
            case "--dry-run": dryRun = true
            case "--json": json = true
            case "--view", "--config", "--data", "--at", "--press", "--timeout":
                rest.append(argument)
                if i + 1 < arguments.count { rest.append(arguments[i + 1]) }
                i += 1
            default:
                if key == nil, !argument.hasPrefix("-") || argument == "-" {
                    key = argument
                } else {
                    rest.append(argument)
                }
            }
            i += 1
        }
        guard let key, !key.isEmpty else { return Output(status: 2, stderr: "vestal: press needs a key\n\(usage)\n") }
        guard dryRun else {
            guard rest.isEmpty, !json else {
                return Output(status: 2, stderr: "vestal: only --dry-run takes options\n\(usage)\n")
            }
            var request = IPCRequest(.press)
            request.key = key
            do {
                let response = try send(request)
                return response.ok
                    ? Output(status: 0)
                    : Output(status: 1, stderr: "vestal: \(response.error ?? "press failed")\n")
            } catch IPCError.notRunning {
                return Output(status: 1, stderr: "vestal: not running (--dry-run works without an instance)\n")
            } catch {
                return Output(status: 1, stderr: "vestal: \(error)\n")
            }
        }

        let options: RenderCommands.Options
        switch RenderCommands.parse(rest) {
        case .failure(let error): return Output(status: 2, stderr: "vestal: \(error.description)\n\(usage)\n")
        case .success(let parsed): options = parsed
        }
        let prepared: RenderCommands.Prepared
        switch RenderCommands.prepare(options, local: true, runsNothing: true, environment: environment, home: home,
                                      platform: platform, client: client) {
        case .failure(let failure): return failure.output
        case .success(let p): prepared = p
        }
        guard let session = prepared.session, let data = prepared.data else { return Output(status: 1) }
        let normalized = RenderKeyMap.normalize(key)
        guard let binding = session.binding(for: normalized) else {
            let text = "key \(normalized): not bound in view \(session.view)\n"
            return json ? Output(status: 1, stdout: AnyJSON.object(["key": .string(normalized), "binding": .null]).canonicalText() + "\n")
                        : Output(status: 1, stdout: text)
        }
        let popupBefore = session.popup != nil
        let effects = session.key(normalized, data: data, now: prepared.now)
        let described = effects.map { describe($0, session: session, popupBefore: popupBefore) }
        if json {
            var object: [String: AnyJSON] = [
                "key": .string(normalized),
                "binding": .object(["level": .string(binding.level), "action": binding.action]),
                "does": .array(described.map(AnyJSON.string)),
            ]
            if let id = binding.id { object["binding"] = .object(["level": .string(binding.level), "id": .string(id), "action": binding.action]) }
            return Output(status: 0, stdout: AnyJSON.object(object).canonicalText() + "\n")
        }
        var lines = ["key: \(normalized)",
                     "binding: \(binding.level)" + (binding.id.map { " \($0)" } ?? ""),
                     "action: \(binding.action.canonicalText())"]
        lines += described.map { "does: \($0)" }
        if described.isEmpty { lines.append("does: nothing") }
        return Output(status: 0, stdout: lines.joined(separator: "\n") + "\n")
    }

    /// One effect in words.
    static func describe(_ effect: RenderActionEffect, session: RenderSession, popupBefore: Bool) -> String {
        switch effect {
        case .run(let argv, let env, let timeout, let refreshAfter, let optimistic, let source):
            var text = "run \(AnyJSON.array(argv.map(AnyJSON.string)).canonicalText())"
            if !env.isEmpty { text += " with env \(env.keys.sorted().joined(separator: ", "))" }
            text += ", timeout \(Int(min(timeout ?? RenderActionRunner.defaultTimeout, 1e9)))s"
            if optimistic != nil, let source { text += ", optimistic update of \(source)" }
            if !refreshAfter.isEmpty { text += ", then refresh \(refreshAfter.joined(separator: ", "))" }
            return text
        case .open(let target): return "open \(target)"
        case .openRefused(let target): return "refuse to open \(target) (data-derived, not http, https or mailto)"
        case .copy(let text): return "copy \(AnyJSON.string(text).canonicalText())"
        case .refresh(let names): return "refresh \(names.isEmpty ? "nothing (no source)" : names.joined(separator: ", "))"
        case .media(let command, let source): return "media \(command)" + (source.map { " on \($0)" } ?? "")
        case .audio(let command, _): return "audio \(command)"
        case .timer(let command, _): return "timer \(command)"
        case .toggleTodo(let path, let line, _, _, _): return "tick off line \(line) of \(path)"
        case .hide: return "hide the dashboard"
        case .changed:
            if let popup = session.popup {
                return session.infoOpen ? "open the info popup" : "open a popup (width \(Int(popup.width)))" + (popupBefore ? ", replacing the open one" : "")
            }
            return popupBefore ? "close the popup" + ", view \(session.view)" : "show view \(session.view)"
        }
    }
}
