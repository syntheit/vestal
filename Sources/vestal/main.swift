import Foundation
import VestalCore
#if os(macOS)
import VestalMac
#endif
#if os(Linux)
import VestalLinux
#endif

// MARK: - Entry
//
// `vestal` with a command is the CLI (VestalCore's `CLI` decides, this file
// carries it out); with none, or with `daemon`, it becomes the resident app:
// the dashboard on macOS, the headless app on Linux (no UI there yet).
// A running instance is found through its unix socket (VestalCore's IPC),
// which also keeps it single: no pid files.

func emit(_ output: CLI.Output) -> Never {
    FileHandle.standardOutput.write(Data(output.stdout.utf8))
    FileHandle.standardError.write(Data(output.stderr.utf8))
    exit(output.status)
}

/// `show`/`toggle` with nothing running: start the dashboard, which comes up
/// shown. On Linux that is the headless app, started detached like bare
/// `vestal`; its reply to the next command says there is no UI.
func launchInstance() throws {
    #if os(macOS)
    try VestalApp.launchInstance()
    #else
    try CLI.spawnDetached(executable: CLI.executablePath)
    #endif
}

/// What `vestal fetch --local` (or with no instance) reads the built-in
/// source types with.
var sourcePlatform: SourcePlatform {
    #if os(macOS)
    return VestalApp.sourcePlatform
    #elseif os(Linux)
    return LinuxPlatform.sources
    #else
    return SourcePlatform()
    #endif
}

/// `vestal capabilities`: what this build and machine can do.
var capabilitiesHost: CapabilitiesCommand.Host {
    #if os(macOS)
    return CapabilitiesCommand.Host(
        ui: "SwiftUI",
        screenshot: .init(true, "offscreen with the app's renderer (`vestal screenshot`); no window or permission needed"),
        hotkey: .init(true, "`hotkey` in the config (Carbon)"),
        platform: sourcePlatform)
    #elseif os(Linux)
    let wayland = ProcessInfo.processInfo.environment["WAYLAND_DISPLAY"].map { !$0.isEmpty } ?? false
    return CapabilitiesCommand.Host(
        ui: "GTK 4 (layer shell)",
        screenshot: wayland
            ? .init(true, "offscreen with the GTK renderer (`vestal screenshot`)")
            : .init(false, "needs a Wayland session (WAYLAND_DISPLAY is not set); `vestal render` works anywhere"),
        hotkey: .init(false, "not grabbed on Wayland: bind `vestal toggle` in the compositor (Hyprland: bind = , Home, exec, vestal toggle)"),
        platform: sourcePlatform)
    #else
    return CapabilitiesCommand.Host(ui: nil, screenshot: .init(false, "no renderer in this build"),
                                    hotkey: .init(false, "not supported"), platform: sourcePlatform)
    #endif
}

/// `vestal screenshot`'s offscreen renderer: the render-file command of this
/// build's UI, why there is none when it can't run, and whether it takes
/// `--size`, `--scale` and `--background` (the GTK window is the screen).
var screenshotRenderer: (renderer: ScreenshotCommand.Renderer?, unsupported: String?, fixedSize: Bool) {
    #if os(macOS)
    return ({ MacRenderFileCommand.run($0) }, nil, true)
    #elseif os(Linux)
    guard let display = ProcessInfo.processInfo.environment["WAYLAND_DISPLAY"], !display.isEmpty else {
        return (nil, "the GTK renderer needs a Wayland session (WAYLAND_DISPLAY is not set)", false)
    }
    return ({ RenderFileCommand.run($0) }, nil, false)
    #else
    return (nil, "this build has no renderer", true)
    #endif
}

// The UIs' development entry point: draws a render-model JSON file, on
// screen with GTK (VestalLinux/RenderFileCommand.swift) or offscreen to a PNG
// on macOS (VestalMac/Render/RenderFileCommand.swift). Not in `CLI` yet,
// since it exists only until the render engine drives the UI.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "render-file" {
    #if os(Linux)
    exit(RenderFileCommand.run(Array(CommandLine.arguments.dropFirst(2))))
    #elseif os(macOS)
    exit(MacRenderFileCommand.run(Array(CommandLine.arguments.dropFirst(2))))
    #endif
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

case .command(.sources(let arguments)):
    emit(SourceCommands.sources(arguments, client: { try IPCClient.send($0, timeout: $1) }))

case .command(.fetch(let arguments)):
    emit(SourceCommands.fetch(arguments, platform: sourcePlatform, client: { try IPCClient.send($0, timeout: $1) }))

case .command(.eval(let arguments)):
    emit(EvalCommand.run(arguments, platform: sourcePlatform, client: { try IPCClient.send($0, timeout: $1) }))

case .command(.render(let arguments)):
    emit(RenderCommands.render(arguments, platform: sourcePlatform, client: { try IPCClient.send($0, timeout: $1) }))

case .command(.explain(let arguments)):
    emit(RenderCommands.explain(arguments, platform: sourcePlatform, client: { try IPCClient.send($0, timeout: $1) }))

case .command(.schema(let arguments)):
    emit(ConfigCommands.schema(arguments))

case .command(.docs(let arguments)):
    emit(DocsCommand.run(arguments))

case .command(.icons(let arguments)):
    emit(IconsCommand.run(arguments))

case .command(.subscribe(let arguments)):
    if case .success(let options) = SubscribeCommand.parse(arguments), let view = options.view,
       let failure = CLI.checkView(view) {
        emit(failure)
    }
    emit(SubscribeCommand.run(arguments, write: { FileHandle.standardOutput.write(Data($0.utf8)) }))

case .command(.capabilities(let arguments)):
    emit(CapabilitiesCommand.run(arguments, host: capabilitiesHost, client: { try IPCClient.send($0, timeout: $1) }))

case .command(.screenshot(let arguments)):
    let (renderer, unsupported, fixedSize) = screenshotRenderer
    emit(ScreenshotCommand.run(arguments, platform: sourcePlatform, client: { try IPCClient.send($0, timeout: $1) },
                               renderer: renderer, unsupported: unsupported, fixedSize: fixedSize))

case .command(.sendRequest(let request)):
    if let view = request.view, let failure = CLI.checkView(view) { emit(failure) }
    emit(CLI.send(request, client: { try IPCClient.send($0) }, launch: launchInstance))

case .command(.send(let command)):
    emit(CLI.send(command, client: { try IPCClient.send($0) }, launch: launchInstance))

case .command(.statusJSON):
    emit(CLI.send(.status, json: true, client: { try IPCClient.send($0) }, launch: launchInstance))

case .command(.start(let hidden)):
    // Take the socket before any window exists, so a second `vestal` never
    // opens one. Commands that come in before the app is up wait in the
    // inbox; the handler runs on the main queue.
    let server = IPCServer.forRequests(queue: .main) { request, reply in
        MainActor.assumeIsolated { ResidentInbox.shared.deliver(request, reply: reply) }
    }
    // `subscribe` streams the render model of the engine the app attaches
    // to SubscriptionHub.shared (EXTENSIBILITY.md §10.8).
    server.subscriptionHandler = { request, stream in
        MainActor.assumeIsolated { SubscriptionHub.shared.add(request, stream) }
    }
    switch CLI.claim(hidden: hidden, start: { try server.start() }, client: { try IPCClient.send($0) }) {
    case .run:
        #if os(macOS)
        VestalApp.run(hidden: hidden, server: server)
        #elseif os(Linux)
        HeadlessApp.run(hidden: hidden, server: server, platform: LinuxPlatform.headless())
        #else
        HeadlessApp.run(hidden: hidden, server: server, platform: HeadlessPlatform())
        #endif
    case .exit(let output):
        emit(output)
    }
}
