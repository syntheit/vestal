#if os(macOS)
import AppKit
import Foundation
import QuartzCore
import SwiftUI
import VestalCore

// MARK: - Headless render benchmark (`vestal bench-render`)
//
//   vestal bench-render --config <path> --data <dir> [--seconds <n>] [--at <time>]
//                       [--size <w>x<h>] [--view <name>] [--poll <n>] [--realtime] [--verify]
//
// What a shown dashboard does every second, with no window: the session
// renders the `now` tick (as the engine's queue does), the engine's diff
// turns it into a patch, the store applies it, and SwiftUI updates and lays
// out the dashboard in an offscreen NSHostingView (never in a window, so
// nothing is drawn on screen). The ticks run back to back with the clock
// moved a second each (`--realtime`: one a second, on the run loop). Prints
// the CPU time per tick of each step, the layout calls per tick and the
// node ids the first patch replaces. `--poll <n>`: every n ticks, every
// source the view reads is fetched again with the same data (what the
// runtime's polls mostly bring). A patch the store refuses is answered as
// the app does, with the whole model. `theme.background` is not drawn: the
// numbers are those of `background: "none"`.
//
// `--verify` checks that each tick's model is the one a whole render gives
// (what the tick replays is still true), also lengthens and shortens some
// texts every few ticks (sizes change deep in the tree), then checks that
// every node's frame after all the patches is the frame a fresh render of
// the last model gives: the layouts' caches never keep a stale
// measurement. Exit 1 when either differs.

public enum RenderBench {
    static let usage = """
    usage: vestal bench-render --config <path> --data <dir> [--seconds <n>] [--at <time>] [--size <w>x<h>]
                               [--view <name>] [--poll <n>] [--realtime] [--verify]
    """

    static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("vestal bench-render: \(message)\n".utf8))
        return 2
    }

    public static func run(_ arguments: [String]) -> Int32 {
        var rest: [String] = []
        var seconds = 20
        var width = 1512.0, height = 982.0
        var realtime = false
        var verify = false
        var churn = 0
        var i = 0
        func value() -> String? {
            i += 1
            return i < arguments.count ? arguments[i] : nil
        }
        while i < arguments.count {
            let argument = arguments[i]
            switch argument {
            case "--seconds":
                guard let v = value().flatMap(Int.init), v > 0 else { return fail("--seconds takes a count\n\(usage)") }
                seconds = v
            case "--size":
                let parts = value()?.split(separator: "x").compactMap { Double($0) } ?? []
                guard parts.count == 2, parts.allSatisfy({ $0 >= 1 }) else { return fail("--size takes <w>x<h>\n\(usage)") }
                width = parts[0]; height = parts[1]
            case "--realtime":
                realtime = true
            case "--verify":
                verify = true
            case "--poll":
                guard let v = value().flatMap(Int.init), v >= 0 else { return fail("--poll takes a count of seconds\n\(usage)") }
                churn = v
            case "--config", "--data", "--at", "--view":
                guard let v = value() else { return fail("\(argument) needs a value\n\(usage)") }
                rest += [argument, v]
            default:
                return fail("unknown argument '\(argument)'\n\(usage)")
            }
            i += 1
        }
        guard rest.contains("--data") else { return fail("give the fixtures with --data\n\(usage)") }
        let options: RenderCommands.Options
        switch RenderCommands.parse(rest) {
        case .failure(let error): return fail("\(error.description)\n\(usage)")
        case .success(let parsed): options = parsed
        }
        let prepared: RenderCommands.Prepared
        switch RenderCommands.prepare(options, local: true, platform: VestalApp.sourcePlatform,
                                      client: { try IPCClient.send($0, timeout: $1) }) {
        case .failure(let failure):
            FileHandle.standardError.write(Data(failure.output.stderr.utf8))
            return failure.output.status
        case .success(let p):
            prepared = p
        }
        guard let session = prepared.session, let data = prepared.data else { return fail("no local session") }

        return MainActor.assumeIsolated {
            let store = RenderStore { _ in }
            var snapshot = prepared.snapshot
            store.apply(snapshot)
            let collector = verify ? FrameCollector() : nil
            let hosting = host(store, collector: collector, width: width, height: height)

            var engine = 0.0, apply = 0.0, layout = 0.0
            var sizes = 0, places = 0, alignments = 0, ops = 0, resyncs = 0
            var firstPatch: [String]?
            var failure: String?
            /// One evaluation, as the engine publishes it and the app applies it.
            @MainActor func evaluate(at moment: Date, changed: Set<String>, tick: Int?) {
                let t0 = cpuSeconds()
                var next = session.render(data: data, now: moment, changed: changed, tick: tick != nil)
                if verify, let tick {
                    // The tick's model is a whole render's.
                    let whole = RenderSession(model: session.model, view: session.view)
                    whole.timeZone = session.timeZone
                    whole.locale = session.locale
                    let fresh = whole.render(data: data, now: moment)
                    if fresh.root != next.root || fresh.popup != next.popup {
                        failure = "the model at tick \(tick) differs from a whole render"
                    }
                    next.root = Self.reword(next.root, tick: tick)
                }
                let (model, patch) = RenderEngine.patch(from: snapshot, to: next)
                let t1 = cpuSeconds()
                LayoutCounters.reset()
                snapshot = model
                if let patch {
                    let applied = store.changesRows(patch)
                        ? withAnimation(.easeInOut(duration: 0.3)) { store.apply(patch) } : store.apply(patch)
                    if !applied {
                        // As the app does: the whole model again.
                        resyncs += 1
                        var whole = session.render(data: data, now: moment)
                        whole.seq = model.seq + 1
                        if verify, let tick { whole.root = Self.reword(whole.root, tick: tick) }
                        store.apply(whole)
                        snapshot = whole
                    }
                }
                let t2 = cpuSeconds()
                Self.flush(hosting)
                let t3 = cpuSeconds()
                engine += t1 - t0; apply += t2 - t1; layout += t3 - t2
                sizes += LayoutCounters.sizes; places += LayoutCounters.places; alignments += LayoutCounters.alignments
                ops += patch?.ops.count ?? 0
                if tick == 1 {
                    firstPatch = (patch?.ops ?? []).map { op in
                        switch op {
                        case .replace(let id, _): return id
                        case .root: return "(root)"
                        case .popup: return "(popup)"
                        case .theme: return "(theme)"
                        case .views: return "(views)"
                        case .diagnostics: return "(diagnostics)"
                        case .unknown: return "(unknown)"
                        }
                    }
                }
            }
            let start = cpuSeconds(), wallStart = CACurrentMediaTime()
            for tick in 1...seconds {
                if realtime {
                    let due = wallStart + Double(tick)
                    while CACurrentMediaTime() < due {
                        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: due - CACurrentMediaTime()))
                    }
                }
                let moment = prepared.now.addingTimeInterval(Double(tick))
                // Half a second before the tick, a poll of every source that
                // brings the same data, as the runtime's fetches mostly do.
                if churn > 0, tick % churn == 0 {
                    evaluate(at: moment.addingTimeInterval(-0.5), changed: session.sourcesRead, tick: nil)
                }
                evaluate(at: moment, changed: [], tick: tick)
                if let failure {
                    print("verify: FAILED: \(failure)")
                    return 1
                }
            }
            let total = cpuSeconds() - start, wall = CACurrentMediaTime() - wallStart
            let n = Double(seconds)
            func ms(_ seconds: Double) -> String { String(format: "%.3f ms", seconds / n * 1000) }
            print("ticks: \(seconds)\(realtime ? " (realtime)" : "")")
            print("per tick: engine \(ms(engine)), apply \(ms(apply)), swiftui+layout \(ms(layout)), total \(ms(total))")
            print(String(format: "layout calls per tick: sizeThatFits %.1f, placeSubviews %.1f, alignment %.1f",
                         Double(sizes) / n, Double(places) / n, Double(alignments) / n))
            print(String(format: "patch ops per tick: %.2f", Double(ops) / n) + ", whole models resent: \(resyncs)")
            print("first tick replaces: \((firstPatch ?? []).joined(separator: ", "))")
            if realtime { print(String(format: "CPU: %.2f%% of one core", total / wall * 100)) }
            guard let collector else { return 0 }

            // The frames after the patches against a fresh render's.
            let window = CGRect(x: 0, y: 0, width: width, height: height)
            let patched = collector.frames(of: store, window: window)
            let freshStore = RenderStore { _ in }
            freshStore.apply(snapshot)
            let freshCollector = FrameCollector()
            _ = host(freshStore, collector: freshCollector, width: width, height: height)
            let fresh = freshCollector.frames(of: freshStore, window: window)
            let differ = zip(patched, fresh).filter { $0 != $1 }
            if patched.count != fresh.count || !differ.isEmpty {
                print("verify: FAILED (\(patched.count) frames patched, \(fresh.count) fresh, \(differ.count) differ)")
                for (a, b) in differ.prefix(10) { print("  \(a)\n  \(b)") }
                return 1
            }
            print("verify: \(fresh.count) frames identical to a fresh render")
            return 0
        }
    }

    /// The dashboard as the app hosts it, with no window.
    @MainActor
    static func host(_ store: RenderStore, collector: FrameCollector?, width: Double, height: Double) -> NSView {
        let view = NSHostingView(rootView: RenderDashboardView(store: store, aurora: false)
            .environment(\.renderFrames, collector))
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        flush(view)
        return view
    }

    /// The transaction SwiftUI schedules for a change, then layout.
    @MainActor
    static func flush(_ view: NSView) {
        CFRunLoopRunInMode(.defaultMode, 0, true)
        view.layoutSubtreeIfNeeded()
    }

    /// `node` with some texts (not mono ones) longer or shorter, depending
    /// on the tick: a change of size deep in the tree.
    static func reword(_ node: RenderNode, tick: Int) -> RenderNode {
        var node = node
        if case .text(var text) = node.content, text.font != "mono" {
            let hash = node.id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xffff }
            if hash % 3 == tick % 3 {
                text.text += String(repeating: "W", count: (tick / 3) % 4)
                node.content = .text(text)
            }
        }
        if !node.children.isEmpty { node.children = node.children.map { reword($0, tick: tick) } }
        return node
    }

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }
}
#endif
