import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Metal
import CrtCore

struct ContentView: View {
    @Environment(AppState.self) private var state
    // CRT_SHOW_EXPORT=1 / CRT_PALETTE_FADE=<seconds>: dev hooks for
    // screenshot verification (see DEVELOPMENT.md).
    @State private var showExport =
        ProcessInfo.processInfo.environment["CRT_SHOW_EXPORT"] == "1"
    private let paletteFadeSeconds =
        ProcessInfo.processInfo.environment["CRT_PALETTE_FADE"].flatMap(Double.init) ?? 2.0
    @State private var paletteVisible = true
    @State private var palettePinned = false   // pointer is over the palette itself
    @State private var paletteRect: CGRect = .zero
    /// Presets shipped in the app's presets folder, listed under Save/Load.
    private let builtInPresets = BuiltInPreset.discover()
    private let hoverLog = ProcessInfo.processInfo.environment["CRT_HOVER_LOG"] == "1"
    /// Fade bookkeeping lives in a plain class so per-mouse-move updates
    /// don't invalidate the view body.
    @State private var fade = FadeTimer()

    private final class FadeTimer {
        var task: Task<Void, Never>?
        /// The pointer can start outside the window, which delivers an
        /// immediate `.ended` — don't hide until the user has hovered once,
        /// so the palette is discoverable at launch.
        var hasHovered = false
    }

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            VStack(spacing: 0) {
                // Preserve source aspect ratio: PreviewView gets a frame
                // matching the source's aspect, centred in the available
                // space. The view palette floats over the letterbox area and
                // fades out when the pointer goes idle.
                ZStack {
                    Color(white: 0.04)
                    PreviewView()
                        .aspectRatio(state.sourceAspect, contentMode: .fit)
                        .padding(8)
                }
                .overlay(alignment: .bottom) {
                    ViewPalette()
                        // The palette floats over the near-black canvas in
                        // both system modes; its colors assume dark.
                        .environment(\.colorScheme, .dark)
                        .padding(.bottom, 12)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(key: PaletteFrameKey.self,
                                                       value: g.frame(in: .named("previewArea")))
                            }
                        )
                        .opacity(paletteVisible || palettePinned ? 1 : 0)
                        .animation(.easeInOut(duration: 0.25),
                                   value: paletteVisible || palettePinned)
                        .onHover { palettePinned = $0 }
                }
                .coordinateSpace(name: "previewArea")
                .onPreferenceChange(PaletteFrameKey.self) { r in
                    paletteRect = r
                    if hoverLog { print("PALETTE-RECT \(r.integral)") }
                }
                .onContinuousHover(coordinateSpace: .named("previewArea")) { phase in
                    switch phase {
                    case .active(let p):
                        fade.hasHovered = true
                        paletteVisible = true
                        fade.task?.cancel()
                        // Never fade while the pointer rests on the palette:
                        // tooltips need ~2s of stillness, and hover events
                        // stop firing exactly then — so the fade must be
                        // decided by where the pointer *is*, not by whether
                        // it keeps moving.
                        let onPalette = paletteRect.insetBy(dx: -10, dy: -10).contains(p)
                        if hoverLog {
                            print("HOVER active p=\(Int(p.x)),\(Int(p.y)) paletteRect=\(paletteRect.integral) onPalette=\(onPalette)")
                        }
                        guard !onPalette else { return }
                        fade.task = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(paletteFadeSeconds))
                            if !Task.isCancelled { paletteVisible = false }
                        }
                    case .ended:
                        if hoverLog { print("HOVER ended") }
                        fade.task?.cancel()
                        if fade.hasHovered { paletteVisible = false }
                    }
                }

                // On a video the timeline replaces the transport — it has
                // the same play button and scrubber, plus the keyframes.
                if state.timelineEnabled && state.timelineAvailable {
                    TimelineBar()
                } else {
                    TransportBar()
                }
            }
            .frame(minWidth: 480, minHeight: 360)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .toolbar { toolbarContent }
        .task { await runDevHooks() }
    }

    /// CRT_TIMELINE=1 opens the timeline at launch; CRT_TL_DEMO=1 also drops
    /// two keyframes on it; CRT_TL_SELFTEST=<out> builds a two-key animation
    /// programmatically, renders it, and exits — headless end-to-end
    /// verification of the keyframe export path.
    private func runDevHooks() async {
        let env = ProcessInfo.processInfo.environment
        guard env["CRT_TIMELINE"] == "1" || env["CRT_TL_DEMO"] == "1"
                || env["CRT_TL_SELFTEST"] != nil || env["CRT_COMPARE_X"] != nil
                || env["CRT_FRONT"] == "1" || env["CRT_DUMP_TOOLTIPS"] == "1"
                || env["CRT_TL_AUTOKEY_TEST"] == "1"
                || env["CRT_GIF_SELFTEST"] != nil
                || env["CRT_EXPORT_FORMAT"] != nil || env["CRT_NTSC_SET"] != nil
                || env["CRT_NTSC_OFF"] == "1" || env["CRT_INTEGER_OFF"] == "1"
                || env["CRT_DUMP_NTSC_LAYOUT"] == "1" || env["CRT_PANEL_BENCH"] == "1"
                || env["CRT_PRESET_ROUNDTRIP"] != nil || env["CRT_LOAD_BUILTIN"] != nil
                || env["CRT_VIDEO_TL_TEST"] != nil || env["CRT_PLAY_BENCH"] != nil || env["CRT_LOOP_TEST"] != nil || env["CRT_STILL_LOOP_TEST"] != nil || env["CRT_PLAY_FRAME_CHECK"] != nil
                || env["CRT_COMPARE_OFF"] == "1" || env["CRT_WINDOW_SIZE"] != nil
                || env["CRT_ZOOM"] != nil else { return }
        var tries = 0
        while tries < 100 && !((state.sourceTexture != nil) && state.chain != nil) {
            try? await Task.sleep(for: .milliseconds(100))
            tries += 1
        }
        if let f = env["CRT_EXPORT_FORMAT"].flatMap(ExportFormat.init(rawValue:)) {
            state.exportFormat = f
        }
        if env["CRT_SNAP"] == "1" { state.snapExportToScanlineGrid = true }
        // CRT_NTSC_SET="key=value,key=value" / CRT_NTSC_OFF=1 — bisect the
        // VHS stage headlessly when chasing a rendering artifact.
        if let pairs = env["CRT_NTSC_SET"] {
            for pair in pairs.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let key = String(kv[0]), raw = String(kv[1])
                if raw == "true" || raw == "false" {
                    state.setNtscValue(key, raw == "true")
                } else if let d = Double(raw) {
                    state.setNtscValue(key, raw.contains(".") ? d as Any : Int(d) as Any)
                }
            }
        }
        if env["CRT_NTSC_OFF"] == "1" { state.ntscEnabled = false }
        if let z = env["CRT_ZOOM"].flatMap(Float.init) { state.zoom = z }
        // CRT_STILL_LOOP_TEST=<out.mp4>: loop a still->video export.
        if let out = env["CRT_STILL_LOOP_TEST"] {
            guard let src = state.sourceTexture else { print("SLOOP FAIL"); exit(1) }
            let loops = env["CRT_LOOP_N"].flatMap(Int.init) ?? 3
            state.timelineDuration = 2; state.timelineFPS = 24
            let base = state.timelineTotalFrames
            let preset = state.presetsRoot.appendingPathComponent(state.selectedPreset.relativePath)
            let settings = Mp4Exporter.Settings(
                outputURL: URL(fileURLWithPath: out), outputWidth: 480, outputHeight: 360,
                downscale: state.downscaleSpec, presetPath: preset.path,
                codec: .h264, averageBitrate: 6_000_000)
            do {
                try await Mp4Exporter(context: state.context).exportStill(
                    source: src, totalFrames: base * loops, fps: state.timelineFPS,
                    paramValues: state.paramValues, settings: settings,
                    ntscSettingsJSON: state.ntscStage?.settingsJSON(), progress: { _ in })
                print("SLOOP wrote base=\(base) loops=\(loops) expectedFrames=\(base * loops)")
                exit(0)
            } catch { print("SLOOP FAIL: \(error)"); exit(1) }
        }
        // CRT_LOOP_TEST=<out.mp4>: export the loaded VIDEO twice through and
        // report duration/frames so looping can be checked headlessly.
        if let out = env["CRT_LOOP_TEST"] {
            guard let vs = state.videoSource else { print("LOOP FAIL: not a video"); exit(1) }
            let loops = env["CRT_LOOP_N"].flatMap(Int.init) ?? 2
            let preset = state.presetsRoot.appendingPathComponent(state.selectedPreset.relativePath)
            let settings = Mp4Exporter.Settings(
                outputURL: URL(fileURLWithPath: out),
                outputWidth: 480, outputHeight: 720,
                downscale: state.downscaleSpec, presetPath: preset.path,
                codec: .h264, averageBitrate: 6_000_000, loopCount: loops)
            let ntscJSON = (state.ntscEnabled && state.ntscAvailable)
                ? state.ntscStage?.settingsJSON() : nil
            do {
                try await Mp4Exporter(context: state.context).export(
                    source: vs, paramValues: state.paramValues, settings: settings,
                    ntscSettingsJSON: ntscJSON, progress: { _ in })
                print("LOOP wrote \(out) loops=\(loops) sourceFrames=\(vs.totalFrames) sourceDuration=\(String(format: "%.2f", vs.durationSeconds))")
                exit(0)
            } catch {
                print("LOOP FAIL: \(error)"); exit(1)
            }
        }
        // CRT_PLAY_FRAME_CHECK=<n>: play to frame n, then check that the
        // frame it decoded matches the SEEKED frame n more closely than its
        // neighbours. Compared by coarse luminance signature, not bytes: the
        // seek path renders via CGImage/sRGB while sequential decode hands
        // back raw BGRA, so identical frames aren't byte-identical.
        if let target = env["CRT_PLAY_FRAME_CHECK"].flatMap(Int.init) {
            guard state.videoSource != nil else { print("FRAMECHK FAIL: not a video"); exit(1) }
            func signature() -> [Double] {
                guard let t = state.sourceTexture else { return [] }
                let w = t.width, h = t.height, bpr = w * 4
                var bytes = [UInt8](repeating: 0, count: h * bpr)
                bytes.withUnsafeMutableBytes { raw in
                    t.getBytes(raw.baseAddress!, bytesPerRow: bpr,
                               from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                }
                var sig: [Double] = []
                let cells = 12
                for gy in 0..<cells {
                    for gx in 0..<cells {
                        var sum = 0.0, n = 0
                        for y in stride(from: gy * h / cells, to: (gy + 1) * h / cells, by: 8) {
                            for x in stride(from: gx * w / cells, to: (gx + 1) * w / cells, by: 8) {
                                let o = y * bpr + x * 4
                                sum += Double(bytes[o]) + Double(bytes[o + 1]) + Double(bytes[o + 2])
                                n += 3
                            }
                        }
                        sig.append(n > 0 ? sum / Double(n) : 0)
                    }
                }
                return sig
            }
            func distance(_ a: [Double], _ b: [Double]) -> Double {
                guard a.count == b.count, !a.isEmpty else { return .infinity }
                return zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count)
            }
            state.ntscEnabled = false
            state.togglePlayback()
            var spins = 0
            while state.currentFrameIndex < target && spins < 400 {
                try? await Task.sleep(for: .milliseconds(20)); spins += 1
            }
            state.stopPlayback()
            try? await Task.sleep(for: .milliseconds(150))
            let playedIndex = state.currentFrameIndex
            let played = signature()

            var best = (index: -1, dist: Double.infinity)
            for candidate in (playedIndex - 2)...(playedIndex + 2) where candidate >= 0 {
                state.currentFrameIndex = candidate
                try? await Task.sleep(for: .milliseconds(350))
                let d = distance(played, signature())
                print(String(format: "FRAMECHK   vs seeked frame %d: distance %.3f", candidate, d))
                if d < best.dist { best = (candidate, d) }
            }
            let ok = best.index == playedIndex
            let verdict = ok ? "FRAMECHK-PASS played \(playedIndex), closest seeked \(best.index)"
                             : "FRAMECHK-FAIL played \(playedIndex), closest seeked \(best.index)"
            print(verdict)
            if let out = env["CRT_BENCH_OUT"] {
                try? (verdict + "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
            exit(ok ? 0 : 1)
        }
        // CRT_PLAY_BENCH=<seconds>: play the loaded video and report the
        // frame rate actually achieved.
        if let secs = env["CRT_PLAY_BENCH"].flatMap(Double.init) {
            guard state.videoSource != nil else { print("PLAYBENCH FAIL: not a video"); exit(1) }
            state.togglePlayback()
            let start = state.currentFrameIndex
            try? await Task.sleep(for: .seconds(secs))
            let advanced = state.currentFrameIndex - start
            let frames = advanced >= 0 ? advanced : advanced + (state.videoSource?.totalFrames ?? 0)
            state.stopPlayback()
            _ = frames   // frame-index delta wraps on looping clips; displayed is the truth
            let line = String(format: "PLAYBENCH displayed %.1f fps, dropped %d (in %.1fs)",
                              Double(state.playbackDisplayed) / secs,
                              state.playbackDropped, secs)
            print(line)
            if let out = env["CRT_BENCH_OUT"] {
                try? (line + "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
            exit(0)
        }
        // CRT_VIDEO_TL_TEST=<out.gif>: keyframe a VIDEO source and render it,
        // then report whether the animation actually varied across the clip.
        if let out = env["CRT_VIDEO_TL_TEST"] {
            guard let vs = state.videoSource else {
                print("VIDEOTL FAIL: source is not a video"); exit(1)
            }
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
                let d = detail()
                print("VIDEOTL \(ok ? "PASS" : "FAIL") \(label)\(d.isEmpty ? "" : "  — \(d)")")
                if !ok { failures += 1 }
            }
            check("timeline available for video", state.timelineAvailable)
            state.timelineEnabled = true
            check("timeline length comes from the clip",
                  abs(state.effectiveTimelineDuration - Double(vs.totalFrames) / Double(vs.frameRate)) < 0.01,
                  "\(state.effectiveTimelineDuration)s")

            // Scrubbing the timeline must move the video frame with it.
            state.scrubTimeline(to: 0.5)
            let midFrame = state.currentFrameIndex
            check("scrubbing the timeline seeks the clip",
                  midFrame > 0 && midFrame < vs.totalFrames - 1, "frame \(midFrame)")
            check("playhead quantizes to that frame",
                  abs(state.playheadT - Double(midFrame) / Double(vs.totalFrames - 1)) < 1e-9)

            // Key a big swing: clean at the start, hammered at the end.
            state.scrubTimeline(to: 0)
            state.setNtscValue("composite_noise_intensity", 0.0)
            state.setKeyframeAtPlayhead()
            state.scrubTimeline(to: 1)
            state.setNtscValue("composite_noise_intensity", 0.9)
            state.setKeyframeAtPlayhead()
            check("two keyframes on a video", state.timelineKeys.count == 2,
                  "\(state.timelineKeys.count)")

            // Auto-key on a video: park on a key and edit it.
            state.scrubTimeline(to: 0)
            state.setNtscValue("composite_noise_intensity", 0.25)
            let keyed = (state.timelineKeys[0].ntscValues["composite_noise_intensity"] as? NSNumber)?.doubleValue
            check("editing while parked rewrites the key (half-frame tolerance)",
                  keyed == 0.25, "stored \(keyed ?? -1)")

            guard let ev = state.makeTimelineEvaluator() else {
                print("VIDEOTL FAIL: no evaluator"); exit(1)
            }
            let a = (ev.ntscValues(at: 0)["composite_noise_intensity"] as? NSNumber)?.doubleValue ?? -1
            let b = (ev.ntscValues(at: 1)["composite_noise_intensity"] as? NSNumber)?.doubleValue ?? -1
            check("animation spans the clip", abs(b - a) > 0.5, "\(a) -> \(b)")

            let preset = state.presetsRoot.appendingPathComponent(state.selectedPreset.relativePath)
            let settings = GifExporter.Settings(
                outputURL: URL(fileURLWithPath: out), width: 240, height: 180, fps: 8,
                downscale: state.downscaleSpec, presetPath: preset.path)
            let ntscJSON = state.ntscStage?.settingsJSON()
            do {
                try await GifExporter(context: state.context).exportVideo(
                    source: vs, paramValues: state.paramValues, settings: settings,
                    ntscSettingsJSON: ntscJSON,
                    frameParams: { i, total in
                        let t = total > 1 ? Double(i) / Double(total - 1) : 0
                        return (shader: ev.shaderParams(at: t), ntscJSON: ev.ntscJSON(at: t))
                    },
                    progress: { _ in })
                let bytes = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
                check("keyframed video export wrote a file", (bytes ?? 0) > 10_000, "\(bytes ?? 0) bytes")
            } catch {
                check("keyframed video export", false, "\(error)")
            }
            print(failures == 0 ? "VIDEOTL-ALL-PASS" : "VIDEOTL-FAILURES \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        // CRT_LOAD_BUILTIN=<name>: load a bundled preset and report what
        // came back, including whether it opened the timeline.
        if let want = env["CRT_LOAD_BUILTIN"] {
            let found = BuiltInPreset.discover()
            print("BUILTIN discovered: \(found.map(\.name))")
            guard let preset = found.first(where: { $0.name == want }) else {
                print("BUILTIN FAIL: no preset named \(want)"); exit(1)
            }
            do { try state.loadLook(from: preset.url) } catch {
                print("BUILTIN FAIL load: \(error)"); exit(1)
            }
            print("BUILTIN loaded \(preset.name): keys=\(state.timelineKeys.count) duration=\(state.timelineDuration) fps=\(state.timelineFPS) timelineOpen=\(state.timelineEnabled)")
            // Keyframed presets must open the timeline. Keyless ones follow
            // whatever "enabled" state they were saved with, so no assertion
            // either way — restoring the saved state faithfully is correct.
            let ok = state.timelineKeys.isEmpty || state.timelineEnabled
            print(ok ? "BUILTIN-PASS" : "BUILTIN-FAIL (keyframed preset did not open the timeline)")
            exit(ok ? 0 : 1)
        }
        // CRT_PRESET_ROUNDTRIP=<path>: save a preset with a keyframed
        // timeline, wipe the state, load it back, and assert everything
        // returned — duration, frame rate, and each key's time, easing and
        // captured values.
        if let path = env["CRT_PRESET_ROUNDTRIP"] {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
                let d = detail()
                print("PRESET \(ok ? "PASS" : "FAIL") \(label)\(d.isEmpty ? "" : "  — \(d)")")
                if !ok { failures += 1 }
            }
            state.timelineEnabled = true
            state.timelineDuration = 7.5
            state.timelineFPS = 12
            state.scrubTimeline(to: 0.25)
            state.setNtscValue("composite_preemphasis", 1.75)
            state.setKeyframeAtPlayhead()
            state.scrubTimeline(to: 0.9)
            state.setNtscValue("composite_preemphasis", 0.5)
            state.setKeyframeAtPlayhead()
            state.setKeyframeEasing(id: state.timelineKeys[0].id, .easeInOut)
            let before = state.timelineKeys
            let firstParam = state.paramDescriptors.first?.name
            let beforeShader = firstParam.flatMap { before[0].shaderParams[$0] }

            let url = URL(fileURLWithPath: path)
            do { try state.saveLook(to: url) } catch {
                print("PRESET FAIL save: \(error)"); exit(1)
            }
            // Wipe, so anything that survives really came from the file.
            state.timelineKeys = []
            state.timelineDuration = 1
            state.timelineFPS = 60
            state.timelineEnabled = false
            do { try state.loadLook(from: url) } catch {
                print("PRESET FAIL load: \(error)"); exit(1)
            }

            check("duration restored", state.timelineDuration == 7.5, "\(state.timelineDuration)")
            check("frame rate restored", state.timelineFPS == 12, "\(state.timelineFPS)")
            check("timeline re-enabled", state.timelineEnabled)
            check("keyframe count restored", state.timelineKeys.count == before.count,
                  "\(state.timelineKeys.count) vs \(before.count)")
            if state.timelineKeys.count == before.count {
                for (i, k) in state.timelineKeys.enumerated() {
                    check("key \(i) time", abs(k.t - before[i].t) < 1e-9, "\(k.t) vs \(before[i].t)")
                    check("key \(i) easing", k.easing == before[i].easing,
                          "\(k.easing.rawValue) vs \(before[i].easing.rawValue)")
                    let ntsc = (k.ntscValues["composite_preemphasis"] as? NSNumber)?.doubleValue
                    let want = (before[i].ntscValues["composite_preemphasis"] as? NSNumber)?.doubleValue
                    check("key \(i) VHS value", ntsc == want, "\(ntsc ?? -1) vs \(want ?? -1)")
                    check("key \(i) shader param count",
                          k.shaderParams.count == before[i].shaderParams.count,
                          "\(k.shaderParams.count) vs \(before[i].shaderParams.count)")
                }
                if let firstParam, let beforeShader {
                    check("key 0 shader value",
                          state.timelineKeys[0].shaderParams[firstParam] == beforeShader,
                          "\(firstParam)")
                }
            }
            print(failures == 0 ? "PRESET-ROUNDTRIP-PASS" : "PRESET-ROUNDTRIP-FAIL \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        // CRT_PANEL_BENCH=1: time a show/hide of each VHS group's children.
        // Toggling a group's boolean adds/removes exactly the subtree that
        // collapsing it does, so this measures collapse cost headlessly.
        if env["CRT_PANEL_BENCH"] == "1" {
            try? await Task.sleep(for: .milliseconds(1200))
            func flush() {
                CATransaction.flush()
                if let cv = NSApp.windows.first?.contentView {
                    cv.layoutSubtreeIfNeeded()
                    cv.displayIfNeeded()
                }
            }
            let groups = (env["CRT_PANEL_BENCH_ORDER"]?.split(separator: ",").map(String.init))
                ?? ["composite_noise", "head_switching", "tracking_noise",
                    "ringing", "luma_noise", "chroma_noise",
                    "vhs_settings", "scale_settings"]
            for g in groups {
                var worst = 0.0, total = 0.0, setMsTotal = 0.0
                var samples = 0
                for _ in 0..<6 {
                    for v in [false, true] {
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        state.setNtscValue(g, v)
                        let tSet = DispatchTime.now().uptimeNanoseconds
                        flush()
                        let t1 = DispatchTime.now().uptimeNanoseconds
                        let ms = Double(t1 - t0) / 1_000_000
                        setMsTotal += Double(tSet - t0) / 1_000_000
                        total += ms; worst = max(worst, ms); samples += 1
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                }
                print(String(format: "BENCH %-22@ total %6.1f ms  = setValue %6.1f ms + ui %6.1f ms   worst %6.1f",
                             g as NSString, total / Double(samples),
                             setMsTotal / Double(samples),
                             (total - setMsTotal) / Double(samples), worst)
)
            }
            print("BENCH-END")
            exit(0)
        }
        if env["CRT_DUMP_NTSC_LAYOUT"] == "1" {
            func dump(_ items: [NtscSetting], _ depth: Int) {
                for s in items {
                    let pad = String(repeating: "  ", count: depth)
                    switch s.kind {
                    case .group(let c):
                        print("\(pad)[group] \(s.label)  (\(s.name))"); dump(c, depth + 1)
                    case .section(let c):
                        print("\(pad)[section] \(s.label)  (\(s.name))"); dump(c, depth + 1)
                    case .float(let lo, let hi, _):
                        print("\(pad)- \(s.label)  (\(s.name))  range \(lo)…\(hi)")
                    default:
                        print("\(pad)- \(s.label)  (\(s.name))")
                    }
                }
            }
            dump(state.ntscDescriptors, 0)
            print("NTSC-LAYOUT-END")
            exit(0)
        }
        if env["CRT_INTEGER_OFF"] == "1" { state.integerScale = false }
        // CRT_WINDOW_SIZE="WxH" — drive the drawable size so both letterbox
        // parities can be reproduced deliberately.
        if let spec = env["CRT_WINDOW_SIZE"] {
            let parts = spec.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, let win = NSApp.windows.first {
                var f = win.frame
                f.size = NSSize(width: parts[0], height: parts[1])
                win.setFrame(f, display: true)
            }
        }
        if env["CRT_COMPARE_OFF"] == "1" { state.compareEnabled = false }
        if let cx = env["CRT_COMPARE_X"].flatMap(Float.init) {
            state.compareLineX = cx
        }
        if env["CRT_FRONT"] == "1" {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        guard env["CRT_TIMELINE"] == "1" || env["CRT_TL_DEMO"] == "1"
                || env["CRT_TL_SELFTEST"] != nil
                || env["CRT_TL_AUTOKEY_TEST"] == "1"
                || env["CRT_GIF_SELFTEST"] != nil else { return }
        state.timelineEnabled = true
        if env["CRT_TL_DEMO"] == "1" {
            state.scrubTimeline(to: 0.2)
            state.setKeyframeAtPlayhead()
            state.scrubTimeline(to: 0.8)
            state.setKeyframeAtPlayhead()
            // Park the playhead exactly on the first key, as clicking its
            // diamond does — makes playhead/diamond centring measurable.
            state.scrubTimeline(to: state.timelineKeys[0].t)
        }
        if env["CRT_DUMP_TOOLTIPS"] == "1" {
            try? await Task.sleep(for: .milliseconds(800))
            print("TOOLTIP-DELAY \(UserDefaults.standard.integer(forKey: "NSInitialToolTipDelay")) ms")
            for k in ["filter_type", "bandwidth_scale", "vertical_scale"] {
                print("NTSC-DEFAULT \(k) = \(state.ntscValues[k] ?? "unset")")
            }
            func walk(_ v: NSView, _ depth: Int) {
                if let t = v.toolTip {
                    // Does a click at this view's centre reach the control
                    // underneath, or does the tooltip overlay swallow it?
                    var hitClass = "?"
                    if let cv = v.window?.contentView {
                        let centre = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: cv)
                        hitClass = cv.hitTest(centre).map { "\(type(of: $0))" } ?? "nil"
                    }
                    print("TOOLTIP [\(type(of: v))] frame=\(v.frame.integral) hitTestAtCentre=\(hitClass) :: \(t.prefix(40))")
                }
                for sub in v.subviews { walk(sub, depth + 1) }
            }
            for w in NSApp.windows {
                if let cv = w.contentView { walk(cv, 0) }
            }
            print("TOOLTIP-DUMP-END")
            exit(0)
        }
        if env["CRT_TL_AUTOKEY_TEST"] == "1" {
            runAutoKeyTest()
        }
        if let gifOut = env["CRT_GIF_SELFTEST"] {
            await runGifSelfTest(out: URL(fileURLWithPath: gifOut))
        }
        guard let out = env["CRT_TL_SELFTEST"] else { return }
        await runTimelineSelfTest(out: URL(fileURLWithPath: out))
    }

    /// Exercises the auto-key rules: editing a parameter while parked on a
    /// keyframe rewrites it; editing between keyframes doesn't; scrubbing
    /// never mutates anything.
    private func runAutoKeyTest() {
        state.timelineEnabled = true
        state.timelineKeys = []
        state.timelineDuration = 5

        state.scrubTimeline(to: 0.2); state.setKeyframeAtPlayhead()
        state.scrubTimeline(to: 0.8); state.setKeyframeAtPlayhead()
        guard state.timelineKeys.count == 2, let param = state.paramDescriptors.first else {
            print("AUTOKEY FAIL: setup"); exit(1)
        }
        let name = param.name
        func keyValue(_ i: Int) -> Float? { state.timelineKeys[i].shaderParams[name] }
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("AUTOKEY \(ok ? "PASS" : "FAIL") \(label) \(detail)")
            if !ok { failures += 1 }
        }

        // 1. Scrubbing alone must not touch stored keyframes.
        let before = (keyValue(0), keyValue(1))
        state.scrubTimeline(to: 0.35)
        state.scrubTimeline(to: 0.62)
        check("scrub-does-not-mutate", (keyValue(0), keyValue(1)) == before,
              "\(String(describing: before)) -> \(String(describing: (keyValue(0), keyValue(1))))")

        // 2. Parked exactly on key 0, a parameter edit rewrites key 0 only.
        state.scrubTimeline(to: 0.2)
        let edited = (param.minimum + param.maximum) / 2 + param.step
        let key1Before = keyValue(1)
        state.setParam(name, edited)
        check("edit-on-keyframe-updates-it", keyValue(0) == edited,
              "stored=\(String(describing: keyValue(0))) expected=\(edited)")
        check("edit-on-keyframe-leaves-others", keyValue(1) == key1Before)

        // 3. Between keyframes, edits are live-only — no keyframe is touched.
        state.scrubTimeline(to: 0.5)
        let snapshot = (keyValue(0), keyValue(1))
        state.setParam(name, param.minimum)
        check("edit-between-keyframes-keys-nothing", (keyValue(0), keyValue(1)) == snapshot,
              "\(String(describing: snapshot)) -> \(String(describing: (keyValue(0), keyValue(1))))")

        // 4. VHS settings follow the same rule.
        state.scrubTimeline(to: 0.8)
        state.setNtscValue("composite_preemphasis", 2.5)
        let stored = (state.timelineKeys[1].ntscValues["composite_preemphasis"] as? NSNumber)?.doubleValue
        check("vhs-edit-on-keyframe-updates-it", stored == 2.5, "stored=\(String(describing: stored))")

        // 5. The magnetic playhead lands exactly on a nearby key.
        state.scrubTimeline(to: 0.2 + 0.002)
        check("playhead-snaps-to-key", state.playheadT == 0.2, "playhead=\(state.playheadT)")

        print(failures == 0 ? "AUTOKEY-ALL-PASS" : "AUTOKEY-FAILURES \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// Renders a keyframed GIF headlessly so the whole path (evaluator →
    /// GifExporter → ImageIO) can be checked without the save panel.
    private func runGifSelfTest(out: URL) async {
        guard let source = state.sourceTexture, state.chain != nil else {
            print("GIF_SELFTEST: no source/chain"); exit(1)
        }
        let env = ProcessInfo.processInfo.environment
        state.timelineEnabled = true
        state.timelineDuration = env["CRT_GIF_SECONDS"].flatMap(Double.init) ?? 2
        state.gifWidth = env["CRT_GIF_W"].flatMap(Int.init) ?? 480
        state.gifFPS = env["CRT_GIF_FPS"].flatMap(Int.init) ?? 12

        // CRT_GIF_PLAIN measures the shipped look (VHS motion only); the
        // default path also exercises keyframe interpolation.
        var ev: TimelineEvaluator? = nil
        if env["CRT_GIF_PLAIN"] != "1" {
            state.scrubTimeline(to: 1); state.setKeyframeAtPlayhead()
            state.scrubTimeline(to: 0)
            var floored: [String: Float] = [:]
            for p in state.paramDescriptors { floored[p.name] = p.minimum }
            state.setAllParams(floored)
            state.setKeyframeAtPlayhead()
            ev = state.makeTimelineEvaluator()
            if ev == nil { print("GIF_SELFTEST: no evaluator"); exit(1) }
        }
        let w = state.gifWidth & ~1
        let h = max(64, Int((Double(w) / Double(state.sourceAspect)).rounded())) & ~1
        let frames = Int((state.timelineDuration * Double(state.gifFPS)).rounded())
        let preset = state.presetsRoot.appendingPathComponent(state.selectedPreset.relativePath)
        let settings = GifExporter.Settings(outputURL: out, width: w, height: h,
                                            fps: state.gifFPS,
                                            downscale: state.downscaleSpec,
                                            presetPath: preset.path)
        let ntscJSON: String? = (state.ntscEnabled && state.ntscAvailable)
            ? state.ntscStage?.settingsJSON() : nil
        do {
            if let vs = state.videoSource {
                try await GifExporter(context: state.context).exportVideo(
                    source: vs, paramValues: state.paramValues,
                    settings: settings, ntscSettingsJSON: ntscJSON, progress: { _ in })
                let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
                print("GIF_SELFTEST video \(w)x\(h) fps=\(state.gifFPS) bytes=\(bytes ?? 0)")
                exit(0)
            }
            try await GifExporter(context: state.context).exportStill(
                source: source, totalFrames: frames,
                paramValues: state.paramValues, settings: settings,
                ntscSettingsJSON: ntscJSON,
                frameParams: ev.map { e in
                    { i, n in
                        let t = n > 1 ? Double(i) / Double(n - 1) : 0
                        return (shader: e.shaderParams(at: t), ntscJSON: e.ntscJSON(at: t))
                    }
                },
                progress: { _ in })
            let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            let bpf = Double(bytes ?? 0) / Double(w * h * frames)
            print("GIF_SELFTEST \(w)x\(h) frames=\(frames) fps=\(state.gifFPS) bytes=\(bytes ?? 0) bytesPerPxPerFrame=\(String(format: "%.3f", bpf))")
            // Sanity-check the supersample rule across regimes.
            for (inH, tgtH) in [(240, 404), (416, 702), (240, 1080), (2160, 702), (1080, 540)] {
                let k = ScanlineGrid.supersampleFactor(inputHeight: inH, targetHeight: tgtH)
                let snap = ScanlineGrid.snappedSize(inputWidth: inH * 4 / 3, inputHeight: inH, targetHeight: tgtH)
                print("SS input=\(inH) target=\(tgtH) -> k=\(k) renderH=\(k*inH) | snapped=\(snap.width)x\(snap.height) rows/line=\(String(format: "%.2f", Double(snap.height)/Double(inH)))")
            }
            exit(0)
        } catch {
            print("GIF_SELFTEST failed: \(error)")
            exit(1)
        }
    }

    private func runTimelineSelfTest(out: URL) async {
        guard let source = state.sourceTexture, state.chain != nil else {
            print("TL_SELFTEST: no image source/chain"); exit(1)
        }
        state.timelineDuration = 2
        state.timelineFPS = 24

        // Key B at t=1: the current (house-default) look.
        state.scrubTimeline(to: 1)
        state.setKeyframeAtPlayhead()
        // Key A at t=0: every shader param at its minimum — a look far from
        // the defaults, so first and last frames must differ visibly.
        state.scrubTimeline(to: 0)
        var floored: [String: Float] = [:]
        for p in state.paramDescriptors { floored[p.name] = p.minimum }
        state.setAllParams(floored)
        state.setKeyframeAtPlayhead()
        state.setKeyframeEasing(id: state.timelineKeys[0].id, .easeInOut)

        guard let ev = state.makeTimelineEvaluator() else {
            print("TL_SELFTEST: no evaluator"); exit(1)
        }
        let preset = state.presetsRoot.appendingPathComponent(state.selectedPreset.relativePath)
        let settings = Mp4Exporter.Settings(
            outputURL: out, outputWidth: 960, outputHeight: 720,
            downscale: state.downscaleSpec, presetPath: preset.path,
            codec: .h264, averageBitrate: 8_000_000)
        let ntscJSON: String? = (state.ntscEnabled && state.ntscAvailable)
            ? state.ntscStage?.settingsJSON() : nil
        let total = state.timelineTotalFrames
        let fps = state.timelineFPS
        do {
            try await Mp4Exporter(context: state.context).exportStill(
                source: source, totalFrames: total, fps: fps,
                paramValues: state.paramValues, settings: settings,
                ntscSettingsJSON: ntscJSON,
                frameParams: { i, n in
                    let t = n > 1 ? Double(i) / Double(n - 1) : 0
                    return (shader: ev.shaderParams(at: t), ntscJSON: ev.ntscJSON(at: t))
                },
                progress: { _ in })
            print("TL_SELFTEST wrote \(out.path) frames=\(total) fps=\(fps)")
            exit(0)
        } catch {
            print("TL_SELFTEST failed: \(error)")
            exit(1)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                openMedia()
            } label: {
                Label("Open…", systemImage: "folder")
            }
            .keyboardShortcut("o")
            .help("Open an image (PNG/JPEG/HEIC) or video (MP4/MOV) — or drop one on the Source panel")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: Binding(
                get: { state.timelineEnabled },
                set: { state.timelineEnabled = $0 }
            )) {
                Label("Animate", systemImage: "timeline.selection")
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.button)
            .disabled(!state.timelineAvailable)
            .help("Keyframe-animate the NTSC and CRT parameters over time and export the result as video")

            Menu {
                Button("Save Preset…") { savePreset() }
                Button("Load Preset…") { loadPreset() }
                if !builtInPresets.isEmpty {
                    Divider()
                    ForEach(builtInPresets) { preset in
                        Button(preset.name) { load(preset.url) }
                    }
                }
            } label: {
                Label("Preset", systemImage: "doc.badge.gearshape")
                    .labelStyle(.titleAndIcon)
            }
            .help("Save or load the whole configuration (downscale + VHS + shader + view) as a JSON file")

            Button {
                showExport.toggle()
            } label: {
                if state.exportWorking && state.videoSource != nil {
                    Label("\(Int((state.exportProgress * 100).rounded()))%",
                          systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                } else {
                    Label("Export…", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
            }
            .keyboardShortcut("e")
            .popover(isPresented: $showExport, arrowEdge: .bottom) {
                ExportPopover()
            }
            .help("Export the current frame as PNG, or the whole video as H.264/HEVC/ProRes")
        }
    }

    // MARK: - toolbar actions

    private func openMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .mpeg4Movie, .quickTimeMovie, .png, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.sourceURL = url
        }
    }

    private var presetTimestamp: String {
        let f = DateFormatter()
        f.dateFormat = "dd-MM-yy HH.mm.ss"
        return f.string(from: Date())
    }

    private func savePreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ntscrt preset \(presetTimestamp).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.saveLook(to: url)
        } catch {
            presetAlert("Couldn't save the preset.", error)
        }
    }

    private func loadPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        do {
            try state.loadLook(from: url)
        } catch {
            presetAlert("Couldn't load the preset.", error)
        }
    }

    private func presetAlert(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Palette bounds in the preview area's coordinate space, so the idle fade
/// can tell whether the pointer is resting on the palette.
private struct PaletteFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct Sidebar: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SourcePanel()
                Divider()
                DownscalePanel()
                Divider()
                NtscPanel()
                Divider()
                ShaderPanel()
            }
            .padding(16)
        }
    }
}
