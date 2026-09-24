import Foundation
import VestalCore
#if os(macOS)
import VestalMac
#endif

// MARK: - Entry
//
// `vestal` with a command is the CLI (VestalCore's `CLI` decides, this file
// carries it out); with none, or with `daemon`, it becomes the resident app.
// A running instance is found through its unix socket (VestalCore's IPC),
// which also keeps it single: no pid files.

func emit(_ output: CLI.Output) -> Never {
    FileHandle.standardOutput.write(Data(output.stdout.utf8))
    FileHandle.standardError.write(Data(output.stderr.utf8))
    exit(output.status)
}

/// `show`/`toggle` with nothing running: start the dashboard, which comes up
/// shown.
func launchInstance() throws {
    #if os(macOS)
    try VestalApp.launchInstance()
    #else
    throw CLIUnsupported()
    #endif
}

struct CLIUnsupported: Error, CustomStringConvertible {
    var description: String { "the dashboard is macOS-only for now; see 'vestal help'" }
}

switch CLI.parse(Array(CommandLine.arguments.dropFirst())) {
case .usageError(let message):
    emit(CLI.Output(status: 2, stderr: "vestal: \(message)\n\(CLI.usage)\n"))

case .command(.version):
    emit(CLI.Output(status: 0, stdout: "vestal \(BuildInfo.build)\n"))

case .command(.help):
    emit(CLI.Output(status: 0, stdout: CLI.usage + "\n"))

case .command(.checkConfig(let arguments)):
    emit(ConfigCommands.checkConfig(arguments))

case .command(.printConfig(let arguments)):
    emit(ConfigCommands.printConfig(arguments))

case .command(.send(let command)):
    emit(CLI.send(command, client: { try IPCClient.send($0) }, launch: launchInstance))

case .command(.start(let hidden)):
    #if os(macOS)
    // Take the socket before any window exists, so a second `vestal` never
    // opens one. Commands that come in before the app is up wait in the
    // inbox; the handler runs on the main queue.
    let server = IPCServer(queue: .main) { command, reply in
        MainActor.assumeIsolated { ResidentInbox.shared.deliver(command, reply: reply) }
    }
    switch CLI.claim(hidden: hidden, start: { try server.start() }, client: { try IPCClient.send($0) }) {
    case .run:
        VestalApp.run(hidden: hidden, server: server)
    case .exit(let output):
        emit(output)
    }
    #else
    _ = hidden
    emit(CLI.Output(status: 1, stderr: "vestal: \(CLIUnsupported())\n"))
    #endif
}
