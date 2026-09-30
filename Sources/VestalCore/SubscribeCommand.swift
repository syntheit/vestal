import Foundation

// MARK: - vestal subscribe
//
//   vestal subscribe [--view <name>] [--while-hidden] [--role ui|observer|control]
//                    [--control] [--minor <n>] [--input]
//
// The reference client of the subscribe protocol, and a debugging tool:
// connects to the running instance and prints every message it sends
// (hello, snapshot, patch, visibility, effect, error) as one JSON line, until
// the instance hangs up or Ctrl-C. `--input` forwards the JSON lines typed on
// stdin (`{"cmd":"key","key":"2"}`), which count only for a `ui` (the most
// recent one) or with `--control`. `--view` asks for that view (with
// control, while the dashboard is shown). Exit 0 when the instance closes
// the stream, 1 when none runs or it refuses, 2 for usage, 4 for an unknown
// view.

public enum SubscribeCommand {
    public typealias Output = ConfigCommands.Output

    public struct Options: Equatable, Sendable {
        public var view: String?
        public var whileHidden = false
        public var role = "observer"
        public var control = false
        public var minor = RenderProtocol.minor
        public var input = false
        public init() {}
    }

    public static let usage = """
        usage: vestal subscribe [--view <name>] [--while-hidden] [--role ui|observer|control] [--control]
                                [--minor <n>] [--input]
        """

    public static func parse(_ arguments: [String]) -> Result<Options, SourceError> {
        var options = Options()
        var rest = arguments[...]
        func value(_ flag: String) throws -> String {
            guard let v = rest.popFirst() else { throw SourceError("\(flag) needs a value") }
            return v
        }
        do {
            while let argument = rest.popFirst() {
                switch argument {
                case "--view": options.view = try value(argument)
                case "--while-hidden": options.whileHidden = true
                case "--role":
                    let role = try value(argument)
                    guard ["ui", "observer", "control"].contains(role) else {
                        throw SourceError("--role: '\(role)' is not ui, observer or control")
                    }
                    options.role = role
                case "--control": options.control = true
                case "--minor":
                    let text = try value(argument)
                    guard let minor = Int(text), minor >= 0 else { throw SourceError("--minor: not a whole number: '\(text)'") }
                    options.minor = minor
                case "--input": options.input = true
                default: throw SourceError("unknown argument '\(argument)'")
                }
            }
        } catch let error as SourceError {
            return .failure(error)
        } catch {
            return .failure(SourceError("\(error)"))
        }
        return .success(options)
    }

    /// The `subscribe` request for `options`.
    public static func request(_ options: Options) -> IPCRequest {
        var request = IPCRequest(.subscribe, view: options.view)
        request.role = options.role
        request.protocols = [RenderProtocol.version]
        request.minor = options.minor
        request.client = "vestal-subscribe/\(BuildInfo.version)"
        request.capabilities = []
        request.whileHidden = options.whileHidden
        request.control = options.control || options.view != nil ? true : nil
        return request
    }

    /// Streams until the instance hangs up; each server line goes to
    /// `write` as it arrives (with its newline).
    public static func run(
        _ arguments: [String],
        paths: [String] = IPC.candidateSocketPaths(),
        write: (String) -> Void,
        readInput: @escaping @Sendable () -> String? = { Swift.readLine() }
    ) -> Output {
        let options: Options
        switch parse(arguments) {
        case .failure(let error): return Output(status: 2, stderr: "vestal: \(error.description)\n\(usage)\n")
        case .success(let parsed): options = parsed
        }
        let stream: IPCStream
        do {
            stream = try IPCClient.openStream(request(options), paths: paths)
        } catch IPCError.notRunning {
            return Output(status: 1, stderr: "vestal: not running\n")
        } catch {
            return Output(status: 1, stderr: "vestal: \(error)\n")
        }
        defer { stream.close() }
        if options.input {
            Thread.detachNewThread {
                while let line = readInput() {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    guard (try? stream.send(line: text)) != nil else { return }
                }
            }
        }
        var first = true
        var failure: String?
        while let line = stream.readLine() {
            if first {
                first = false
                // An instance that can't stream answers like a one-shot
                // request: {"error": …, "ok": false}.
                if let response = try? IPCResponse(jsonLine: Data(line.utf8)), !response.ok {
                    return Output(status: 1, stderr: "vestal: \(response.error ?? "subscribe failed")\n")
                }
            }
            write(line + "\n")
            if case .success(let json)? = Optional(AnyJSON.parse(Data(line.utf8))),
               json.objectValue?["type"]?.stringValue == "error" {
                failure = json.objectValue?["message"]?.stringValue ?? "error"
            }
        }
        if let failure { return Output(status: 1, stderr: "vestal: \(failure)\n") }
        return Output(status: 0)
    }
}
