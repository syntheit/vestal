import Foundation
import VestalCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(macOS)
import VestalMac
#endif

// MARK: - CLI subcommands
//
// Vestal launches the dashboard when invoked with no arguments. With a
// subcommand it acts as a control surface — used by toggle scripts, skhd
// bindings, Hammerspoon, etc. The PID file lets us identify a running GUI
// instance without relying on `pgrep` (so the binary works without /bin
// in PATH or in sandbox environments).

let vestalPidFile = "\(NSTemporaryDirectory())vestal.pid"

func writeVestalPid() {
    try? "\(getpid())".write(toFile: vestalPidFile, atomically: true, encoding: .utf8)
}

func runningVestalPid() -> pid_t? {
    guard let raw = try? String(contentsOfFile: vestalPidFile, encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = pid_t(trimmed) else { return nil }
    return kill(pid, 0) == 0 ? pid : nil   // signal 0 = liveness check
}

func detachedRelaunch() {
    // Fork+exec self via Foundation.Process and return immediately. Parent
    // exits without waitUntilExit; macOS re-parents the orphan child to
    // launchd so it survives. Inherits env from parent (so VESTAL_CONFIG
    // carries through to the GUI launch). stdio routed to /dev/null so
    // the caller's terminal doesn't stay tethered.
    let task = Process()
    task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    task.arguments = []
    task.standardInput  = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice
    task.standardError  = FileHandle.nullDevice
    try? task.run()
}

func printVestalUsage(to stream: FileHandle) {
    let text = """
    Usage: vestal [command]

    Commands:
      toggle               Show or hide the dashboard
      show                 Show the dashboard (no-op if already shown)
      hide                 Hide the dashboard (no-op if not shown)
      check-config [path]  Check a config file (default: the one vestal loads)
      print-config [path]  Print the effective config as JSON, defaults merged in
      version              Print version and build code
      help                 Show this message

    With no command, vestal launches the dashboard directly (macOS only).
    The config is read from $VESTAL_CONFIG, else $XDG_CONFIG_HOME/vestal/config.json
    (default ~/.config/vestal/config.json); see docs/CONFIG.md.
    """
    stream.write(Data((text + "\n").utf8))
}

let cliArgs = CommandLine.arguments
if cliArgs.count >= 2 {
    switch cliArgs[1] {
    case "version", "--version", "-v":
        print("vestal \(BuildInfo.version) (\(BuildInfo.commit))")
        exit(0)
    case "help", "--help", "-h":
        printVestalUsage(to: FileHandle.standardOutput)
        exit(0)
    case "check-config", "print-config":
        let arguments = Array(cliArgs.dropFirst(2))
        let output = cliArgs[1] == "check-config"
            ? ConfigCommands.checkConfig(arguments)
            : ConfigCommands.printConfig(arguments)
        FileHandle.standardOutput.write(Data(output.stdout.utf8))
        FileHandle.standardError.write(Data(output.stderr.utf8))
        exit(output.status)
    #if os(macOS)
    case "toggle":
        if let pid = runningVestalPid() {
            _ = kill(pid, SIGTERM)
        } else {
            detachedRelaunch()
        }
        exit(0)
    case "show":
        if runningVestalPid() == nil { detachedRelaunch() }
        exit(0)
    case "hide":
        if let pid = runningVestalPid() { _ = kill(pid, SIGTERM) }
        exit(0)
    #else
    case "toggle", "show", "hide":
        FileHandle.standardError.write(Data("vestal: '\(cliArgs[1])' needs the dashboard, which is macOS-only for now\n".utf8))
        exit(1)
    #endif
    default:
        FileHandle.standardError.write(Data("vestal: unknown command '\(cliArgs[1])'\n".utf8))
        printVestalUsage(to: FileHandle.standardError)
        exit(2)
    }
}

// MARK: - GUI launch (no subcommand)

#if os(macOS)
writeVestalPid()
VestalApp.run()
#else
FileHandle.standardError.write(Data("vestal: the dashboard is macOS-only for now; see 'vestal help'\n".utf8))
exit(1)
#endif
