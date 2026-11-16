import Foundation
import Darwin
import AppKit
import QuartzCore
import CrtCore

/// CRT_PRESET_CYCLE=<seconds>: load every bundled look preset in turn, as a
/// user clicking down the Preset menu would, and report per preset how long
/// the load blocked the main thread, the longest main-thread stall while it
/// ran, the frame rate, and the process / GPU memory. Then load each preset
/// after three very different ones and report any setting that differs —
/// state one preset leaves behind for the next.
/// CRT_PRESET_CYCLE_PLAY=1 plays the source video while cycling.
@MainActor
enum PresetCycleCheck {
    /// Pings the main queue from a background thread; the delay before each
    /// ping runs is how long the main thread was busy (a pinwheel shows
    /// after about 2 s of this).
    final class StallMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private var worst: Double = 0
        private var worstAt: Double = 0
        private var over100 = 0
        private var since = DispatchTime.now().uptimeNanoseconds
        private var running = true

        func start() {
            Thread.detachNewThread { [self] in
                // CRT_STALL_SAMPLE_DIR: profile the process (sample(1)) while
                // the main thread is stuck, at most six times.
                let sampleDir = ProcessInfo.processInfo.environment["CRT_STALL_SAMPLE_DIR"]
                var captures = 0
                var pending: [UInt64] = []
                let pendingLock = NSLock()
                while self.isRunning {
                    let sent = DispatchTime.now().uptimeNanoseconds
                    pendingLock.lock()
                    let oldest = pending.first
                    pending.append(sent)
                    pendingLock.unlock()
                    if let dir = sampleDir, captures < 6, let oldest,
                       sent - oldest > 400_000_000 {
                        captures += 1
                        let file = "\(dir)/stall-\(captures).txt"
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                        p.arguments = ["\(getpid())", "1", "-file", file]
                        try? p.run()
                        p.waitUntilExit()
                        pendingLock.lock(); pending.removeAll(); pendingLock.unlock()
                    }
                    DispatchQueue.main.async {
                        pendingLock.lock(); pending.removeAll { $0 == sent }; pendingLock.unlock()
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6
                        self.lock.lock()
                        if ms > self.worst {
                            self.worst = ms
                            self.worstAt = Double(Int64(bitPattern: sent) - Int64(bitPattern: self.since)) / 1e6
                        }
                        if ms > 100 { self.over100 += 1 }
                        self.lock.unlock()
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
        func stop() { lock.lock(); running = false; lock.unlock() }
        /// The worst stall since the last take, and when it began (ms after
        /// that take).
        func take() -> (worst: Double, at: Double, over100: Int) {
            lock.lock()
            defer { worst = 0; worstAt = 0; over100 = 0; since = DispatchTime.now().uptimeNanoseconds; lock.unlock() }
            return (worst, worstAt, over100)
        }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1e6 : -1
    }

    static func run(state: AppState, seconds: Double, play: Bool) async {
        let all = BuiltInPreset.discover()
        // CRT_PRESET_CYCLE_ONLY="A|B|C": just these, in this order.
        let only = ProcessInfo.processInfo.environment["CRT_PRESET_CYCLE_ONLY"]?.split(separator: "|").map(String.init)
        let presets = only.map { names in names.compactMap { n in all.first { $0.name == n } } } ?? all
        let monitor = StallMonitor()
        monitor.start()
        if play, state.videoSource != nil { state.togglePlayback() }
        try? await Task.sleep(for: .seconds(1))
        _ = monitor.take()
        print(String(format: "CYCLE start footprint %.0f MB, GPU %.0f MB",
                     footprintMB(), Double(state.context.device.currentAllocatedSize) / 1e6))
        for p in presets {
            _ = monitor.take()
            let displayed0 = state.playbackDisplayed
            let t0 = ContinuousClock.now
            do { try state.loadLook(from: p.url) } catch { print("CYCLE FAIL \(p.name): \(error)") }
            let loadMs = Double((ContinuousClock.now - t0).components.attoseconds) / 1e15
                + Double((ContinuousClock.now - t0).components.seconds) * 1000
            if play, state.videoSource != nil, !state.videoPlaying { state.togglePlayback() }
            // Count the frames that reached the screen (playbackDisplayed
            // restarts whenever the pipeline does, e.g. on a keyframed load).
            var shown = 0, lastFrame = state.currentFrameIndex
            let end = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < end {
                try? await Task.sleep(for: .milliseconds(5))
                if state.currentFrameIndex != lastFrame { shown += 1; lastFrame = state.currentFrameIndex }
            }
            let stall = monitor.take()
            _ = displayed0
            let fps = Double(shown) / seconds
            print(String(format: "CYCLE %-28@ load %6.1f ms  worst stall %6.0f ms at %5.0f ms  >100ms %3d  fps %5.1f  footprint %5.0f MB  GPU %5.0f MB",
                         p.name as NSString, loadMs, stall.worst, stall.at, stall.over100, fps,
                         footprintMB(), Double(state.context.device.currentAllocatedSize) / 1e6))
        }
        if state.videoPlaying { state.stopPlayback() }
        monitor.stop()

        // Carry-over: each preset loaded after three different ones must
        // come out the same.
        func canonical() -> String {
            let d = state.lookDictionary()
            let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        func flatten(_ v: Any, _ path: String, into out: inout [String: String]) {
            if let d = v as? [String: Any] {
                for (k, x) in d { flatten(x, path.isEmpty ? k : "\(path).\(k)", into: &out) }
            } else if let a = v as? [Any] {
                for (i, x) in a.enumerated() { flatten(x, "\(path)[\(i)]", into: &out) }
            } else {
                out[path] = "\(v)"
            }
        }
        let priors = ["15 second glitches", "Chunky webcam", "Dirty VCR", "Readable Text"]
        let priorURLs = priors.compactMap { name in all.first { $0.name == name }?.url }
        var carried = 0
        for p in presets where ProcessInfo.processInfo.environment["CRT_PRESET_CYCLE_NO_CARRY"] == nil {
            var results: [(String, [String: String])] = []
            for (name, url) in zip(priors, priorURLs) {
                try? state.loadLook(from: url)
                try? state.loadLook(from: p.url)
                var flat: [String: String] = [:]
                flatten(state.lookDictionary(), "", into: &flat)
                results.append((name, flat))
                _ = canonical()
            }
            let base = results[0].1
            var diffs: [String: Set<String>] = [:]
            for (_, r) in results.dropFirst() {
                for key in Set(base.keys).union(r.keys) where base[key] != r[key] {
                    diffs[key, default: []].insert("\(base[key] ?? "∅") vs \(r[key] ?? "∅")")
                }
            }
            if !diffs.isEmpty {
                carried += 1
                print("CARRY \(p.name): \(diffs.count) settings depend on the previous preset")
                for key in diffs.keys.sorted().prefix(12) {
                    print("    \(key): \(diffs[key]!.sorted().joined(separator: "; "))")
                }
            }
        }
        print(carried == 0 ? "CARRY-NONE" : "CARRY-FOUND \(carried) presets")
        exit(0)
    }
}

/// CRT_EDIT_BENCH=<preset name>: with that preset loaded (paused), time how
/// long one knob change keeps the main thread busy — the edit, the panels
/// rebuilding and the preview re-rendering — for a knob in each panel.
@MainActor
enum EditBench {
    static func run(state: AppState, preset: String) async {
        if let p = BuiltInPreset.discover().first(where: { $0.name == preset }) {
            try? state.loadLook(from: p.url)
        }
        if let f = ProcessInfo.processInfo.environment["CRT_EDIT_BENCH_FRAME"].flatMap(Int.init) {
            state.currentFrameIndex = f
        }
        try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["CRT_EDIT_BENCH_SETTLE"] ?? "") ?? 2))
        func flush() {
            CATransaction.flush()
            for w in NSApp.windows {
                w.contentView?.layoutSubtreeIfNeeded()
                w.contentView?.displayIfNeeded()
            }
        }
        let shaderParam = state.paramDescriptors.first?.name ?? ""
        let edits: [(String, (Int) -> Void)] = [
            ("shader param", { i in state.setParam(shaderParam, i % 2 == 0 ? 0.3 : 0.4) }),
            ("ntsc number", { i in state.setNtscValue("snow_intensity", i % 2 == 0 ? 0.01 : 0.02) }),
            ("glitch knob", { i in state.setGlitchValue("ghost_level", i % 2 == 0 ? 0.1 : 0.2) }),
            ("vcr knob", { i in state.setGlitchValue("tape_wear", i % 2 == 0 ? 0.1 : 0.2) }),
            ("deck tension", { i in state.setGlitchValue("back_tension", i % 2 == 0 ? 0.1 : 0.2) }),
            ("digital knob", { i in state.setDigitalValue("sensor_noise", i % 2 == 0 ? 0.1 : 0.2) }),
        ]
        print("EDIT at frame \(state.currentFrameIndex), glitch time \(state.glitchTime), stage on \(state.glitchStageActive), vcr \(state.vcrEnabled), animate \(state.animatePreview)")
        let monitor = PresetCycleCheck.StallMonitor()
        monitor.start()
        for (name, edit) in edits {
            var times: [Double] = []
            for i in 0..<8 {
                try? await Task.sleep(for: .milliseconds(300))
                _ = monitor.take()
                let t0 = DispatchTime.now().uptimeNanoseconds
                edit(i)
                flush()
                let direct = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                try? await Task.sleep(for: .milliseconds(500))
                times.append(max(direct, monitor.take().worst))
            }
            times.sort()
            print(String(format: "EDIT %-14@ median %6.1f ms  worst %6.1f ms", name as NSString,
                         times[times.count / 2], times.last ?? 0))
        }
        exit(0)
    }
}

/// CRT_CHAIN_BENCH=1: how long picking each CRT shader blocks the main
/// thread the first time (the compile) and the second (cached).
@MainActor
enum ChainBench {
    static func run(state: AppState) async {
        for round in ["first", "again"] {
            for p in Presets.all {
                let t0 = DispatchTime.now().uptimeNanoseconds
                state.selectedPreset = p
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                print(String(format: "CHAIN %-6@ %-22@ %7.1f ms  GPU %5.0f MB", round as NSString,
                             p.displayName as NSString, ms,
                             Double(state.context.device.currentAllocatedSize) / 1e6))
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        exit(0)
    }
}
