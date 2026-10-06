import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Metal
import CrtCore

struct ContentView: View {
    @Environment(AppState.self) private var state
    // CRT_SHOW_EXPORT=1 / CRT_PALETTE_FADE=<seconds>: dev hooks for
    // screenshot verification (see DEVELOPMENT.md).
    @State private var showExport =
        ProcessInfo.processInfo.environment["CRT_SHOW_EXPORT"] == "1"
    // CRT_SHOW_HOWL=1 opens the Howlaround panel once the source has loaded.
    @State private var showHowlaround = false
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
                // matching the source's aspect, centered in the available
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
        .onAppear { state.installKeyMonitor() }
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
                || env["CRT_ZOOM"] != nil
                || env["CRT_DOWNSCALE_W"] != nil || env["CRT_CACHE_CHECK"] != nil
                || env["CRT_EXPORT_TOGGLE_CHECK"] != nil || env["CRT_GLITCH"] != nil
                || env["CRT_GLITCH_EXPORT_CHECK"] != nil
                || env["CRT_GLITCH_PANEL_SNAPSHOT"] != nil
                || env["CRT_SLIDER_SELFTEST"] != nil || env["CRT_SLIDER_E2E"] != nil
                || env["CRT_SPACE_SELFTEST"] != nil
                || env["CRT_SAVE_LOOK"] != nil || env["CRT_LOOK"] != nil
                || env["CRT_HOWL_RENDER"] != nil || env["CRT_HOWL_DRAFT_CHECK"] != nil
                || env["CRT_HOWL_PANEL_SNAPSHOT"] != nil || env["CRT_SHOW_HOWL"] == "1"
                || env["CRT_FEEDBACK_PRESET_CHECK"] != nil
                || env["CRT_FIELD_FOCUS_CHECK"] != nil || env["CRT_PAD_E2E"] != nil
                || env["CRT_VIDEO_PNG_CHECK"] != nil else { return }
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
        // CRT_LOOK=<path>: open with a look file loaded (any path, not just
        // the bundled presets) — for rendering or inspecting a saved look.
        if let path = env["CRT_LOOK"] {
            do { try state.loadLook(from: URL(fileURLWithPath: path)) }
            catch { print("LOOK FAIL: \(error)") }
        }
        if env["CRT_NTSC_OFF"] == "1" { state.ntscEnabled = false }
        if let z = env["CRT_ZOOM"].flatMap(Float.init) { state.zoom = z }
        if let w = env["CRT_DOWNSCALE_W"].flatMap(Int.init) { state.downscaleWidth = w }
        // CRT_GLITCH="vertical_hold=0.6,signal_strength=0.3" — switch the
        // glitch stage on with these knobs (GlitchParam ids).
        if let pairs = env["CRT_GLITCH"] {
            state.glitchEnabled = true
            for pair in pairs.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, let v = Double(kv[1]) { state.setGlitchValue(String(kv[0]), v) }
            }
        }
        // CRT_HOWL="zoom=0.8,center_x=0.1" sets Screen Loop knobs for the
        // other Screen Loop hooks (old ids and the old drift are read too).
        if let pairs = env["CRT_HOWL"] {
            var values: [String: Double] = [:]
            for pair in pairs.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, let v = Double(kv[1]) { values[String(kv[0])] = v }
            }
            state.howlaroundValues.merge(HowlaroundParam.migrated(values)) { _, new in new }
        }
        if env["CRT_SHOW_HOWL"] == "1" { showHowlaround = true }
        // CRT_FIELD_FOCUS_CHECK=1: a number field that has keyboard focus
        // while its slider moves the value must not put the old value back
        // when focus leaves it (it did: the Screen Loop panel focuses Zoom's
        // field on opening, and opening the export settings reset Zoom).
        // Real panel, real field, real first-responder changes.
        if env["CRT_FIELD_FOCUS_CHECK"] != nil {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print("FIELDFOCUS \(ok ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
                if !ok { failures += 1 }
            }
            state.howlaroundValues["zoom"] = 0.87
            let host = NSHostingView(rootView: HowlaroundPanel().environment(state))
            host.frame = CGRect(x: 0, y: 0, width: 1040, height: 700)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(800))
            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            let field = views(host).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.stringValue == "87" }
            check("found Zoom's field", field != nil)
            if let field {
                window.makeFirstResponder(field)                      // focused, as on opening
                try? await Task.sleep(for: .milliseconds(300))
                state.setHowlaroundValue("zoom", 0.64)                // the slider moves it
                try? await Task.sleep(for: .milliseconds(300))
                window.makeFirstResponder(nil)                        // focus leaves (the export button)
                try? await Task.sleep(for: .milliseconds(300))
                let zoom = state.howlaroundSettings["zoom"]
                check("the slider's value survives focus leaving the field", abs(zoom - 0.64) < 1e-9,
                      "zoom \(zoom)")
                check("the field shows it", field.stringValue == "64", "field shows \"\(field.stringValue)\"")
                // Typing still works: type, then click away.
                window.makeFirstResponder(field)
                try? await Task.sleep(for: .milliseconds(200))
                field.currentEditor()?.selectAll(nil)
                field.currentEditor()?.insertText("75")
                try? await Task.sleep(for: .milliseconds(200))
                window.makeFirstResponder(nil)
                try? await Task.sleep(for: .milliseconds(300))
                let typed = state.howlaroundSettings["zoom"]
                check("a typed value still commits when focus leaves", abs(typed - 0.75) < 1e-9, "zoom \(typed)")
            }
            print(failures == 0 ? "FIELDFOCUS-PASS" : "FIELDFOCUS-FAIL \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        // CRT_VIDEO_PNG_CHECK=<dir>: PNG export from a clip — the frame under
        // the playhead, through the Export button's own render (exportPNG).
        // Two frames are two pictures; the same frame twice is the same file
        // (its VHS noise is seeded by frame number, as in a video export);
        // the size is the export size. Also draws the Export popover there.
        if let dir = env["CRT_VIDEO_PNG_CHECK"] {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print("VIDEOPNG \(ok ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
                if !ok { failures += 1 }
            }
            guard let vs = state.videoSource, vs.totalFrames > 41 else {
                print("VIDEOPNG FAIL needs a clip of 42+ frames (CRT_SOURCE=<clip>)"); exit(1)
            }
            let folder = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func export(frame i: Int, as name: String) async -> (data: Data, size: CGSize)? {
                state.currentFrameIndex = i
                let version = state.sourceVersion
                for _ in 0..<50 where state.sourceVersion == version {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                let url = folder.appendingPathComponent("\(name).png")
                let ok = await withCheckedContinuation { c in
                    state.exportPNG(to: url, size: state.exportVideoSize) { c.resume(returning: $0) }
                }
                guard ok, let data = try? Data(contentsOf: url), let image = NSImage(data: data),
                      let rep = image.representations.first else { return nil }
                return (data, CGSize(width: rep.pixelsWide, height: rep.pixelsHigh))
            }
            let a = await export(frame: 10, as: "frame-10")
            let b = await export(frame: 40, as: "frame-40")
            let again = await export(frame: 10, as: "frame-10-again")
            check("frame 10 exports", a != nil)
            check("frame 40 is a different picture", a != nil && b != nil && a!.data != b!.data)
            check("frame 10 again is the same file", a != nil && again != nil && a!.data == again!.data)
            let want = state.exportVideoSize
            check("at the export size", a?.size == CGSize(width: want.width, height: want.height),
                  "\(a.map { "\(Int($0.size.width)) × \(Int($0.size.height))" } ?? "none"), want \(want.width) × \(want.height)")
            check("the VHS stage was on (so the seed mattered)", state.ntscEnabled && state.ntscAvailable)
            // The popover, as the toolbar button shows it with a clip loaded.
            let host = NSHostingView(rootView: ExportPopover().environment(state)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            try? await Task.sleep(for: .milliseconds(500))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("popover.png"))
            }
            print(failures == 0 ? "VIDEOPNG-PASS" : "VIDEOPNG-FAIL \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        // CRT_PAD_E2E=1: the vanishing-point dots on the real panel, driven
        // by mouse and key events through AppKit's event queue (the path a
        // mouse takes) over the real draft player: drag the dot, pull the
        // ring out of it, drag the arrow, nudge with the arrow keys, snap the
        // ring back, double-click each — checking the stored settings after
        // every step, and that plain clicks move nothing.
        if env["CRT_PAD_E2E"] != nil {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print("PADE2E \(ok ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
                if !ok { failures += 1 }
            }
            state.howlaroundValues = HowlaroundParam.defaultValues
            // Launched from a shell the app can't come to the front, so its
            // window isn't key — where AppKit spends a click on bringing the
            // window forward unless the view takes first clicks.
            final class FirstClickHost<Content: View>: NSHostingView<Content> {
                override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
            }
            let host = FirstClickHost(rootView: HowlaroundPanel().environment(state))
            host.frame = CGRect(x: 0, y: 0, width: 1040, height: 700)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(1200))
            guard VanishingPointPad.lastPad != nil else {
                print("PADE2E FAIL the pad isn't drawn"); exit(1)
            }
            print("PADE2E window key: \(window.isKeyWindow), pad frame \(VanishingPointPad.lastPad!.frame.integral)")
            var pad: HowlaroundPad { VanishingPointPad.lastPad! }

            var s: HowlaroundSettings { state.howlaroundSettings }
            /// A point of the pad in the window's coordinates. SwiftUI's global
            /// space is the whole window's, title bar included, top down.
            func windowPoint(_ p: CGPoint) -> NSPoint {
                let g = VanishingPointPad.lastFrame
                return NSPoint(x: g.minX + p.x, y: window.frame.height - (g.minY + p.y))
            }
            func deliver(_ e: NSEvent) {
                // Posted through the event queue when the window is key; handed
                // to it directly when it isn't (the queue routes keys to the key window).
                if window.isKeyWindow { NSApp.postEvent(e, atStart: false) } else { window.sendEvent(e) }
            }
            func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) {
                deliver(NSEvent.mouseEvent(with: type, location: windowPoint(p), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!)
            }
            func click(_ p: CGPoint) async {
                mouse(.leftMouseDown, p); mouse(.leftMouseUp, p)
                try? await Task.sleep(for: .milliseconds(300))
            }
            func drag(from a: CGPoint, by d: CGSize) async {
                mouse(.leftMouseDown, a)
                try? await Task.sleep(for: .milliseconds(40))
                for i in 1...12 {
                    let f = CGFloat(i) / 12
                    mouse(.leftMouseDragged, CGPoint(x: a.x + d.width * f, y: a.y + d.height * f))
                    try? await Task.sleep(for: .milliseconds(16))
                }
                mouse(.leftMouseUp, CGPoint(x: a.x + d.width, y: a.y + d.height))
                try? await Task.sleep(for: .milliseconds(300))
            }
            func doubleClick(_ p: CGPoint) async {
                mouse(.leftMouseDown, p, clicks: 1); mouse(.leftMouseUp, p, clicks: 1)
                mouse(.leftMouseDown, p, clicks: 2); mouse(.leftMouseUp, p, clicks: 2)
                try? await Task.sleep(for: .milliseconds(400))
            }
            /// An arrow key: 123 left, 124 right, 125 down, 126 up.
            func arrow(_ code: UInt16, shift: Bool = false) async {
                let scalar: UInt32 = [123: 0xF702, 124: 0xF703, 125: 0xF701, 126: 0xF700][code]!
                let chars = String(Character(Unicode.Scalar(scalar)!))
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    deliver(NSEvent.keyEvent(with: type, location: .zero,
                                             modifierFlags: shift ? [.shift, .numericPad, .function] : [.numericPad, .function],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             characters: chars, charactersIgnoringModifiers: chars,
                                             isARepeat: false, keyCode: code)!)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.004) -> Bool { abs(a - b) <= tolerance }
            func at(_ p: SIMD2<Double>) -> String { String(format: "(%.4f, %.4f)", p.x, p.y) }
            let w = pad.frame.width, h = pad.frame.height

            var before = state.howlaroundValues
            await arrow(124)
            check("before any dot is clicked, an arrow key moves nothing", state.howlaroundValues == before)
            await click(pad.startPoint)
            check("a click on the dot moves nothing", state.howlaroundValues == before)

            await drag(from: pad.startPoint, by: CGSize(width: w * 0.1, height: h * 0.1))
            check("dragging the dot moves the vanishing point",
                  near(s["center_x"], -0.1) && near(s["center_y"], -0.12), at(s.vanishingPoint))
            check("…and with no drift, the ring comes along", s.driftTarget == s.vanishingPoint)

            // The ring sits round the dot: grab it 11 points out from the middle.
            await drag(from: CGPoint(x: pad.startPoint.x + 11, y: pad.startPoint.y),
                       by: CGSize(width: w * 0.3, height: -h * 0.2))
            check("pulling the ring out of the dot makes a drift",
                  near(s["drift_x"], 0.3) && near(s["drift_y"], -0.2),
                  String(format: "drift (%.4f, %.4f)", s["drift_x"], s["drift_y"]))
            check("…and leaves the vanishing point where it was",
                  near(s["center_x"], -0.1) && near(s["center_y"], -0.12), at(s.vanishingPoint))

            var end = s.driftTarget
            await drag(from: pad.startPoint, by: CGSize(width: -w * 0.05, height: 0))
            check("dragging the dot now leaves the ring where it is",
                  near(s.driftTarget.x, end.x, 1e-9) && near(s.driftTarget.y, end.y, 1e-9)
                      && near(s["center_x"], -0.15), "\(at(s.vanishingPoint)) → \(at(s.driftTarget))")

            var start = s.vanishingPoint
            end = s.driftTarget
            let middle = CGPoint(x: (pad.startPoint.x + pad.endPoint.x) / 2, y: (pad.startPoint.y + pad.endPoint.y) / 2)
            await drag(from: middle, by: CGSize(width: 0, height: h * 0.1))
            check("dragging the arrow moves both",
                  near(s.vanishingPoint.y, start.y + 0.1) && near(s.driftTarget.y, end.y + 0.1)
                      && near(s.vanishingPoint.x, start.x, 1e-9), "\(at(s.vanishingPoint)) → \(at(s.driftTarget))")

            start = s.vanishingPoint
            await arrow(124)
            check("the right arrow key then nudges both 1%",
                  near(s.vanishingPoint.x, start.x + 0.01, 1e-9) && near(s.driftTarget.x - s.vanishingPoint.x, 0.35),
                  at(s.vanishingPoint))

            await click(pad.endPoint)
            end = s.driftTarget
            await arrow(126, shift: true)
            check("after clicking the ring, Shift-up nudges it 10% up",
                  near(s.driftTarget.y, end.y - 0.1, 1e-9), "\(at(end)) → \(at(s.driftTarget))")

            await drag(from: pad.endPoint, by: CGSize(width: pad.startPoint.x - pad.endPoint.x + 6,
                                                      height: pad.startPoint.y - pad.endPoint.y - 4))
            check("dragging the ring back near the dot lands on it: no drift",
                  s["drift_x"] == 0 && s["drift_y"] == 0, String(format: "drift (%.4f, %.4f)", s["drift_x"], s["drift_y"]))

            await drag(from: CGPoint(x: pad.startPoint.x, y: pad.startPoint.y - 12), by: CGSize(width: -w * 0.2, height: 0))
            check("pulled out again from the ring's top", near(s["drift_x"], -0.2), String(format: "drift_x %.4f", s["drift_x"]))
            await doubleClick(pad.endPoint)
            check("double-clicking the ring removes the drift", s["drift_x"] == 0 && s["drift_y"] == 0,
                  String(format: "drift (%.4f, %.4f)", s["drift_x"], s["drift_y"]))

            // In the picture's corner the dot reaches past it (over the
            // letterbox, or the text below a picture that fills the height),
            // and can be grabbed there.
            state.setHowlaroundValues(["center_x": 0.5, "center_y": 0.5])
            try? await Task.sleep(for: .milliseconds(300))
            await drag(from: CGPoint(x: pad.startPoint.x + 4, y: pad.startPoint.y + 4),
                       by: CGSize(width: -w * 0.2, height: -h * 0.2))
            check("a dot in the corner can be grabbed from outside the picture",
                  near(s["center_x"], 0.3) && near(s["center_y"], 0.3), at(s.vanishingPoint))

            await doubleClick(pad.startPoint)
            check("double-clicking the dot sends the vanishing point to the middle",
                  s.vanishingPoint == .zero && s.driftTarget == .zero, at(s.vanishingPoint))

            before = state.howlaroundValues
            await click(CGPoint(x: pad.frame.maxX - 30, y: pad.frame.minY + 30))
            check("a click elsewhere on the picture moves nothing", state.howlaroundValues == before)
            check("the readout says where things are",
                  state.howlaroundReadout == "Vanishing point in the middle · no drift", state.howlaroundReadout)
            window.orderOut(nil)
            print(failures == 0 ? "PADE2E-PASS" : "PADE2E-FAIL \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        // CRT_FEEDBACK_PRESET_CHECK=1: a Screen Loop preset saves and loads
        // back exactly, and the look presets refuse one with a pointer to the
        // panel (the two kinds live apart).
        if env["CRT_FEEDBACK_PRESET_CHECK"] != nil {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print("FBPRESET \(ok ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
                if !ok { failures += 1 }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fb-preset-check.json")
            var wanted = state.howlaroundValues
            wanted["zoom"] = 0.71; wanted["key"] = 0.4; wanted["delay"] = 13; wanted["seed"] = 42; wanted["spin"] = -30
            state.howlaroundValues = wanted
            state.howlaroundSeconds = 7.5
            do { try state.saveFeedbackPreset(to: url) } catch { check("save", false, "\(error)") }
            state.howlaroundValues = HowlaroundParam.defaultValues
            state.howlaroundSeconds = 5
            do { try state.loadFeedbackPreset(from: url) } catch { check("load", false, "\(error)") }
            check("values come back exactly", state.howlaroundValues == wanted)
            check("a still's length comes back", state.howlaroundSeconds == 7.5)
            // A preset saved by 0.13: British ids, the drift as distance and
            // direction. It loads into today's settings with the same move.
            let old = FileManager.default.temporaryDirectory.appendingPathComponent("fb-preset-v1.json")
            let v1 = #"{"kind": "ntscrt-video-feedback", "version": 1, "values": {"centre_x": -0.5, "centre_y": -0.5, "colour_drift": -0.49, "drift": 0.25, "drift_dir": 90, "zoom": 0.63}}"#
            try? v1.data(using: .utf8)?.write(to: old)
            do { try state.loadFeedbackPreset(from: old) } catch { check("load a 0.13 preset", false, "\(error)") }
            let loaded = state.howlaroundValues
            check("a 0.13 preset loads into today's ids",
                  loaded["center_x"] == -0.5 && loaded["center_y"] == -0.5 && loaded["color_drift"] == -0.49
                      && loaded["zoom"] == 0.63
                      && ["centre_x", "centre_y", "colour_drift", "drift", "drift_dir"].allSatisfy { loaded[$0] == nil },
                  "\(loaded.filter { $0.key.contains("c") || $0.key.contains("drift") })")
            check("…with its drift as a line (25% up)",
                  abs((loaded["drift_x"] ?? 9)) < 1e-12 && abs((loaded["drift_y"] ?? 9) + 0.25) < 1e-12,
                  "drift_x \(loaded["drift_x"] ?? .nan), drift_y \(loaded["drift_y"] ?? .nan)")
            try? FileManager.default.removeItem(at: old)
            do {
                try state.loadLook(from: url)
                check("the look presets refuse a Screen Loop preset", false)
            } catch {
                check("the look presets refuse a Screen Loop preset",
                      error.localizedDescription.contains("Screen Loop panel"), error.localizedDescription)
            }
            check("its folder is separate from the look presets",
                  FeedbackPresets.saveFolder().lastPathComponent == FeedbackPresets.folderName,
                  FeedbackPresets.saveFolder().path)
            try? FileManager.default.removeItem(at: url)
            print(failures == 0 ? "FBPRESET-PASS" : "FBPRESET-FAIL \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        // CRT_HOWL_PANEL_SNAPSHOT=<out.png>: draw the Howlaround panel off
        // screen (the draft video itself doesn't draw this way).
        if let out = env["CRT_HOWL_PANEL_SNAPSHOT"] {
            let tall = env["CRT_HOWL_PANEL_TALL"] == "1"
            let host = NSHostingView(rootView: HowlaroundPanel(height: tall ? 1950 : 700).environment(state)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(x: 0, y: 0, width: 1040, height: tall ? 1950 : 700)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            try? await Task.sleep(for: .seconds(3))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print("HOWL-PANEL-SNAPSHOT \(out)")
            }
            exit(0)
        }
        // CRT_HOWL_DRAFT_CHECK=1: the panel's draft logic — a first draft;
        // knob turns in quick succession render only the last setting; a
        // knob turned mid-render cancels it; never two renders at once.
        if env["CRT_HOWL_DRAFT_CHECK"] != nil {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print("HOWLDRAFT \(ok ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
                if !ok { failures += 1 }
            }
            func settle(_ seconds: Double = 30) async {
                let end = Date().addingTimeInterval(seconds)
                try? await Task.sleep(for: .milliseconds(600))   // past the 350 ms debounce
                while Date() < end && (state.howlDraftWorking || state.howlActiveRenders > 0) {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            state.stopPlayback()
            state.exportInProgress = true
            state.scheduleHowlaroundDraft(delay: .zero)
            await settle()
            let first = state.howlDraftURL
            check("first draft written", first.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                  state.howlDraftStatus)
            // Three turns 100 ms apart: one render, of the last value.
            state.setHowlaroundValue("zoom", 0.6)
            try? await Task.sleep(for: .milliseconds(100))
            state.setHowlaroundValue("roll", 10)
            try? await Task.sleep(for: .milliseconds(100))
            state.setHowlaroundValue("roll", 20)
            let last = state.howlDraftGeneration
            await settle()
            check("quick turns render once, the last setting",
                  state.howlDraftURL?.lastPathComponent == "ntscrt-feedback-draft-\(last).mp4",
                  state.howlDraftURL?.lastPathComponent ?? "no draft")
            check("the old draft file is gone", first.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false)
            // A turn while a draft is rendering cancels it.
            state.setHowlaroundValue("zoom", 0.7)
            var sawWorking = false
            for _ in 0..<100 where !sawWorking {
                try? await Task.sleep(for: .milliseconds(10))
                sawWorking = state.howlActiveRenders > 0
            }
            state.setHowlaroundValue("zoom", 0.75)
            let final = state.howlDraftGeneration
            await settle()
            check("a turn mid-render cancels it and renders the new setting",
                  sawWorking && state.howlDraftURL?.lastPathComponent == "ntscrt-feedback-draft-\(final).mp4",
                  "saw render: \(sawWorking), draft: \(state.howlDraftURL?.lastPathComponent ?? "none")")
            check("never two renders at once", !state.howlOverlapSeen)
            print(failures == 0 ? "HOWLDRAFT-PASS" : "HOWLDRAFT-FAIL \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        // CRT_HOWL_RENDER=<out.mp4|out.gif> renders a howlaround (knobs from
        // CRT_HOWL) through the panel's own render call and exits
        // (CRT_HOWL_DRAFT=1: the draft's length and size instead).
        if let out = env["CRT_HOWL_RENDER"] {
            if let secs = env["CRT_HOWL_SECONDS"].flatMap(Double.init) { state.howlaroundSeconds = secs }
            let draft = env["CRT_HOWL_DRAFT"] == "1"
            let gif = out.hasSuffix(".gif")
            if gif { state.exportFormat = .gif } else if state.exportFormat.isGIF { state.exportFormat = .h264 }
            let size = draft ? state.howlDraftSize : (gif ? state.exportGifSize : state.exportVideoSize)
            state.stopPlayback()
            state.exportInProgress = true
            let started = Date()
            do {
                try await state.renderHowlaround(to: URL(fileURLWithPath: out), gif: gif, size: size,
                                                 draftSeconds: draft ? AppState.howlDraftSeconds : nil,
                                                 cancel: nil, progress: { _ in })
                print(String(format: "HOWL wrote %@ %dx%d in %.1f s (copies %@)", out, size.width, size.height,
                             Date().timeIntervalSince(started),
                             state.howlaroundCopies.map(String.init) ?? "growing"))
                exit(0)
            } catch {
                print("HOWL FAIL: \(error)")
                exit(1)
            }
        }
        // CRT_STILL_LOOP_TEST=<out.mp4>: loop a still->video export.
        if let out = env["CRT_STILL_LOOP_TEST"] {
            guard let src = state.sourceTexture else { print("SLOOP FAIL"); exit(1) }
            let loops = env["CRT_LOOP_N"].flatMap(Int.init) ?? 3
            state.timelineDuration = 2; state.timelineFPS = 24
            let base = state.timelineTotalFrames
            let settings = state.mp4ExportSettings(route: .still,
                                                   outputURL: URL(fileURLWithPath: out),
                                                   size: (480, 360), bitrate: 6_000_000,
                                                   codec: .h264)
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
            // CRT_LOOP_CODEC="ProRes 422" etc. — exercise the .mov path too
            // (the output path's extension must match: .mov for ProRes).
            let codec = env["CRT_LOOP_CODEC"].flatMap(Mp4Exporter.Codec.init(rawValue:)) ?? .h264
            // Set the popover's own state and build the settings the way the
            // Export button does. An earlier version handed loopCount straight
            // to the exporter and so never noticed that the button didn't.
            state.exportLoopCount = loops
            let settings = state.mp4ExportSettings(route: .video,
                                                   outputURL: URL(fileURLWithPath: out),
                                                   size: (480, 720), bitrate: 6_000_000,
                                                   codec: codec)
            let ntscJSON = (state.ntscEnabled && state.ntscAvailable)
                ? state.ntscStage?.settingsJSON() : nil
            do {
                try await Mp4Exporter(context: state.context).export(
                    source: vs, paramValues: state.paramValues, settings: settings,
                    ntscSettingsJSON: ntscJSON, progress: { _ in })
                let written = try await AVURLAsset(url: URL(fileURLWithPath: out))
                    .load(.duration).seconds
                let expected = vs.durationSeconds * Double(loops)
                let ok = abs(written - expected) < 0.25
                print("LOOP \(ok ? "PASS" : "FAIL") wrote \(out) loops=\(loops) sourceFrames=\(vs.totalFrames) sourceDuration=\(String(format: "%.2f", vs.durationSeconds)) writtenDuration=\(String(format: "%.2f", written))")
                exit(ok ? 0 : 1)
            } catch {
                print("LOOP FAIL: \(error)"); exit(1)
            }
        }
        // CRT_PLAY_FRAME_CHECK=<n>: play to frame n, then check that the
        // frame it decoded matches the SEEKED frame n more closely than its
        // neighbors. Compared by coarse luminance signature, not bytes: the
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
        // CRT_SPACE_SELFTEST=1: Space through the app's own event queue (the
        // path a real key press takes): play/pause with the timeline open,
        // tap-vs-pan when zoomed, nothing when the timeline is closed.
        if env["CRT_SPACE_SELFTEST"] != nil {
            var failures = 0
            func check(_ label: String, _ ok: Bool) {
                print("SPACE \(ok ? "PASS" : "FAIL") \(label)")
                if !ok { failures += 1 }
            }
            func key(_ type: NSEvent.EventType, repeatKey: Bool = false) async {
                let window = NSApp.keyWindow ?? NSApp.windows.first
                let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window?.windowNumber ?? 0, context: nil,
                                         characters: " ", charactersIgnoringModifiers: " ",
                                         isARepeat: repeatKey, keyCode: 49)!
                NSApp.postEvent(e, atStart: false)
                try? await Task.sleep(for: .milliseconds(150))
            }
            func playing() -> Bool { state.timelinePlaying || state.videoPlaying }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(300))

            state.timelineEnabled = true
            state.zoom = 1
            let before = playing()
            await key(.keyDown); await key(.keyUp)
            check("Space starts playback with the timeline open", playing() != before)
            await key(.keyDown); await key(.keyUp)
            check("Space again pauses", playing() == before)

            state.zoom = 2
            await key(.keyDown); await key(.keyUp)
            check("zoomed in, a tap still toggles (on release)", playing() != before)
            await key(.keyDown); await key(.keyUp)
            await key(.keyDown)
            state.spacePanned = true                 // as the preview does on a drag
            await key(.keyUp)
            check("zoomed in, a held Space that panned doesn't toggle", playing() == before)

            state.zoom = 1
            state.timelineEnabled = false
            await key(.keyDown); await key(.keyUp)
            check("timeline closed: Space does nothing", playing() == before)
            print(failures == 0 ? "SPACE-SELFTEST-PASS" : "SPACE-SELFTEST-FAIL \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        // CRT_SLIDER_SELFTEST=1: double-click-to-neutral, checked a level
        // below the UI (scripts can't click the app): synthesized double-clicks
        // on a NeutralSlider's knob and track; then every slider in every panel
        // must have an explicit neutral value, listed for review.
        if env["CRT_SLIDER_SELFTEST"] != nil {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print("SLIDER \(ok ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
                if !ok { failures += 1 }
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            let slider = NeutralSlider(frame: NSRect(x: 10, y: 10, width: 280, height: 24))
            slider.minValue = -1; slider.maxValue = 1; slider.doubleValue = 0.6
            window.contentView?.addSubview(slider)
            var fired = 0
            slider.onKnobDoubleClick = { fired += 1 }
            let cell = slider.cell as! NSSliderCell
            let knob = cell.knobRect(flipped: slider.isFlipped)
            let knobInWindow = slider.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
            func click(_ p: NSPoint, count: Int) -> NSEvent {
                NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: count, pressure: 1)!
            }
            slider.mouseDown(with: click(knobInWindow, count: 2))
            check("double-click on the knob resets", fired == 1, "fired \(fired)")
            let trackPoint = slider.convert(NSPoint(x: slider.bounds.minX + 6, y: knob.midY), to: nil)
            check("a point on the track is not the knob", !slider.knobContains(trackPoint))
            check("the knob is the knob", slider.knobContains(knobInWindow))

            // Coverage: explicit neutral values for every slider.
            var missing: [String] = []
            func walk(_ settings: [NtscSetting]) {
                for st in settings {
                    switch st.kind {
                    case .float(let lo, let hi, _):
                        print("NEUTRAL ntsc \(st.name) → \(state.ntscNeutral(st.name, min: lo, max: hi))")
                        if Neutral.ntsc[st.name] == nil { missing.append(st.name) }
                    case .percentage:
                        print("NEUTRAL ntsc \(st.name) → \(state.ntscNeutral(st.name, min: 0, max: 1))")
                        if Neutral.ntsc[st.name] == nil { missing.append(st.name) }
                    case .int(let lo, let hi) where hi - lo <= 10_000:
                        print("NEUTRAL ntsc \(st.name) → \(state.ntscNeutral(st.name, min: Double(lo), max: Double(hi)))")
                        if Neutral.ntsc[st.name] == nil { missing.append(st.name) }
                    case .group(let kids), .section(let kids): walk(kids)
                    default: break
                    }
                }
            }
            walk(state.ntscDescriptors)
            for preset in Presets.all {
                state.selectedPreset = preset
                for _ in 0..<100 where state.paramDescriptors.isEmpty || state.chain == nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .milliseconds(150))
                for p in state.paramDescriptors {
                    let pres = presentation(for: p)
                    guard case .slider = pres.kind else { continue }
                    print("NEUTRAL \(preset.id) \(p.name) [\(p.minimum)…\(p.maximum) default \(state.shaderDefault(p))] → \(state.shaderNeutral(p))")
                    if Neutral.shader[p.name] == nil { missing.append("\(preset.id).\(p.name)") }
                }
            }
            check("every slider has an explicit neutral value", missing.isEmpty, missing.joined(separator: ", "))
            print(failures == 0 ? "SLIDER-SELFTEST-PASS" : "SLIDER-SELFTEST-FAIL \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        // CRT_SLIDER_E2E=1: the whole double-click path on real sidebar
        // sliders, one per panel. The double-click goes through AppKit's own
        // event queue to whatever is under the knob (the path a mouse click
        // takes), and what must reset is the VALUE: the app state, the number
        // field, and the rendered picture — which must match setting the
        // neutral value directly. The knob must follow and STAY: NSSlider's
        // internal view puts it back ~0.3 s later unless PropertySlider holds it.
        if env["CRT_SLIDER_E2E"] != nil {
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print("E2E \(ok ? "PASS" : "FAIL") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
                if !ok { failures += 1 }
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let content = window.contentView else { print("E2E FAIL: no window"); exit(1) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            state.animatePreview = false            // time stands still, so renders compare
            try? await Task.sleep(for: .milliseconds(400))

            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("slider-e2e-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            func render(_ name: String) async -> [UInt8]? {
                let url = tmp.appendingPathComponent("\(name).png")
                let ok = await withCheckedContinuation { c in
                    state.exportPNG(to: url, size: (480, 480)) { c.resume(returning: $0) }
                }
                guard ok, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
                px.withUnsafeMutableBytes { buf in
                    CGContext(data: buf.baseAddress, width: img.width, height: img.height,
                              bitsPerComponent: 8, bytesPerRow: img.width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                        .draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                }
                return px
            }
            // Sweep the sidebar until the slider showing `value` exists (the
            // NTSC and CRT lists are lazy, so the document grows as it goes),
            // then center it in view.
            func findSlider(showing value: Double) async -> NeutralSlider? {
                guard let sv = views(content).compactMap({ $0 as? NSScrollView }).first(where: { sv in
                    sv.documentView.map { views($0).contains { $0 is NeutralSlider } } ?? false
                }), let doc = sv.documentView else { return nil }
                let clip = sv.contentView
                func scroll(to y: CGFloat) async {
                    let maxY = max(0, doc.frame.height - clip.bounds.height)
                    clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
                    sv.reflectScrolledClipView(clip)
                    try? await Task.sleep(for: .milliseconds(250))
                }
                var y: CGFloat = 0
                await scroll(to: y)
                while true {
                    let hits = views(doc).compactMap { $0 as? NeutralSlider }
                        .filter { abs($0.doubleValue - value) < 1e-6 }
                    if hits.count > 1 { print("E2E: \(hits.count) sliders show \(value)"); return nil }
                    if let s = hits.first {
                        // Rows above re-measure as they come into view and
                        // shift it, so re-center until the knob is in view.
                        let knob = (s.cell as! NSSliderCell).knobRect(flipped: s.isFlipped)
                        for _ in 0..<8 where !s.visibleRect.contains(knob) {
                            let r = doc.convert(s.bounds, from: s)
                            await scroll(to: r.midY - clip.bounds.height / 2)
                        }
                        return s
                    }
                    if y >= doc.frame.height - clip.bounds.height { return nil }
                    y += clip.bounds.height * 0.6
                    await scroll(to: y)
                }
            }
            // The number field sits just above its slider, right-aligned.
            func numberField(above slider: NSView) -> NSTextField? {
                let s = slider.convert(slider.bounds, to: nil)
                return views(content).compactMap { $0 as? NSTextField }
                    .filter { $0.isEditable }
                    .map { ($0, $0.convert($0.bounds, to: nil)) }
                    .filter { $0.1.minY >= s.maxY - 4 && $0.1.minY <= s.maxY + 40
                              && $0.1.midX > s.midX && $0.1.minX < s.maxX }
                    .min { $0.1.minY < $1.1.minY }?.0
            }
            // NSSlider only puts the knob back when the first click moved the
            // value. A hand drifting a pixel does that; synthesized events
            // can't hold the button down to drag, but the NTSC case's first
            // click nudges its value by rounding, so that case exercises it
            // (it fails without PropertySlider's hold — checked).
            func doubleClick(_ slider: NSSlider) {
                let knob = (slider.cell as! NSSliderCell).knobRect(flipped: slider.isFlipped)
                let p = slider.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
                for (type, count) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1),
                                      (.leftMouseDown, 2), (.leftMouseUp, 2)] {
                    let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: count,
                                               pressure: type == .leftMouseDown ? 1 : 0)!
                    NSApp.postEvent(e, atStart: false)
                }
            }

            struct Case {
                let name: String
                let test: Double                      // distinctive, so one slider shows it
                let percentField: Bool
                let set: (Double) -> Void             // the setter the panel's binding uses
                let get: () -> Double
                let neutral: (NSSlider) -> Double     // where the app says it resets to
            }
            let bloom = state.paramDescriptors.first { $0.name == "BLOOM_STRENGTH" }
            let cases = [
                Case(name: "Glitch › Signal strength", test: 0.3137, percentField: true,
                     set: { state.setGlitchValue("signal_strength", $0) },
                     get: { state.glitchSettings["signal_strength"] },
                     neutral: { _ in GlitchParam.all.first { $0.id == "signal_strength" }!.defaultValue }),
                Case(name: "NTSC › Composite signal sharpening", test: 1.4321, percentField: false,
                     set: { state.setNtscValue("composite_preemphasis", $0) },
                     get: { state.ntscNumber("composite_preemphasis") },
                     neutral: { state.ntscNeutral("composite_preemphasis", min: $0.minValue, max: $0.maxValue) }),
                Case(name: "CRT › Glow Strength", test: Double(Float(0.65)), percentField: false,
                     set: { state.setParam("BLOOM_STRENGTH", Float($0)) },
                     get: { Double(state.paramValues["BLOOM_STRENGTH"] ?? -1) },
                     neutral: { _ in bloom.map { state.shaderNeutral($0) } ?? -1 }),
            ]
            for c in cases {
                c.set(c.test)
                try? await Task.sleep(for: .milliseconds(300))
                guard let slider = await findSlider(showing: c.test) else {
                    check("\(c.name): slider found in the sidebar", false); continue
                }
                let knob = (slider.cell as! NSSliderCell).knobRect(flipped: slider.isFlipped)
                check("\(c.name): knob in view", slider.visibleRect.contains(knob))
                let expected = c.neutral(slider)
                let before = await render("\(c.name)-before")
                doubleClick(slider)
                // Watch the knob for 1.2 s: once it reaches the reset value it
                // must stay there (a frame or two of correction at most).
                let t0 = ProcessInfo.processInfo.systemUptime
                var reached: Double?, wrongSince: Double?, worst = 0.0
                while ProcessInfo.processInfo.systemUptime - t0 < 1.2 {
                    try? await Task.sleep(for: .milliseconds(5))
                    let now = ProcessInfo.processInfo.systemUptime - t0
                    let onIt = abs(slider.doubleValue - expected) < 1e-6
                    if onIt { reached = reached ?? now; wrongSince = nil }
                    else if reached != nil {
                        wrongSince = wrongSince ?? now
                        worst = max(worst, now - wrongSince!)
                    }
                }
                let value = c.get()
                check("\(c.name): stored value reset", abs(value - expected) < 1e-6,
                      "\(c.test) → \(value), neutral \(expected)")
                check("\(c.name): knob moved to it", reached != nil,
                      reached.map { String(format: "after %.0f ms", $0 * 1000) } ?? "knob at \(slider.doubleValue)")
                check("\(c.name): knob stayed there", abs(slider.doubleValue - expected) < 1e-6 && worst < 0.05,
                      String(format: "knob at %@ after 1.2 s; longest away %.0f ms", "\(slider.doubleValue)", worst * 1000))
                if let field = numberField(above: slider), let shown = Double(field.stringValue) {
                    let want = c.percentField ? expected * 100 : expected
                    check("\(c.name): number field shows it", abs(shown - want) < 1e-3,
                          "field shows \"\(field.stringValue)\"")
                } else {
                    check("\(c.name): number field found", false)
                }
                let after = await render("\(c.name)-after")
                // Reference: the same setter the binding calls, straight to neutral.
                c.set(c.test); c.set(expected)
                try? await Task.sleep(for: .milliseconds(300))
                let reference = await render("\(c.name)-reference")
                let again = await render("\(c.name)-reference2")
                guard let before, let after, let reference, let again else {
                    check("\(c.name): renders", false); continue
                }
                check("\(c.name): renders are repeatable", reference == again)
                check("\(c.name): picture changed on double-click", before != after)
                check("\(c.name): picture matches setting the neutral value directly", after == reference)
            }
            print(failures == 0 ? "SLIDER-E2E-PASS" : "SLIDER-E2E-FAIL \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        // CRT_GLITCH_PANEL_SNAPSHOT=<out.png>: render the Glitch panel on its
        // own (it sits below the long NTSC list, out of a window capture).
        if let out = env["CRT_GLITCH_PANEL_SNAPSHOT"] {
            let panel = GlitchPanel()
                .environment(state)
                .frame(width: 290)
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: panel)
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(x: 0, y: 0, width: 322, height: 1200)
            host.layoutSubtreeIfNeeded()
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print("PANEL-SNAPSHOT \(out) \(Int(host.bounds.width))x\(Int(host.bounds.height))")
            }
            exit(0)
        }
        // CRT_GLITCH_EXPORT_CHECK=<dir>: export every route this source offers
        // through the Export buttons' builders with the glitch stage off, on
        // and healthy, and on and broken; the healthy export must match the
        // off one and the broken one must not. (The gate's exporter tests
        // can't see whether the buttons pass the stage along; this can.)
        if let dir = env["CRT_GLITCH_EXPORT_CHECK"] {
            let outDir = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            state.ntscEnabled = false
            let size = (640, max(64, Int((640 / Double(state.sourceAspect)).rounded())) & ~1)
            var failures = 0
            func firstFrame(_ url: URL) async -> CGImage? {
                if url.pathExtension == "mp4" {
                    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                    gen.requestedTimeToleranceBefore = .zero
                    gen.requestedTimeToleranceAfter = .zero
                    return try? await gen.image(at: .zero).image
                }
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(src, 0, nil)
            }
            func meanDiff(_ a: CGImage, _ b: CGImage) -> Double {
                func px(_ i: CGImage) -> [UInt8] {
                    var p = [UInt8](repeating: 0, count: i.width * i.height * 4)
                    p.withUnsafeMutableBytes { buf in
                        CGContext(data: buf.baseAddress, width: i.width, height: i.height,
                                  bitsPerComponent: 8, bytesPerRow: i.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                            .draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
                    }
                    return p
                }
                let pa = px(a), pb = px(b)
                let n = min(pa.count, pb.count)
                var t = 0
                for k in 0..<n where k % 4 != 3 { t += abs(Int(pa[k]) - Int(pb[k])) }
                return Double(t) / Double(max(1, n * 3 / 4))
            }
            func route(_ name: String, ext: String, export: (URL) async throws -> Void) async {
                var frames: [String: CGImage] = [:]
                for (label, enabled, values) in [("off", false, [String: Double]()),
                                                 ("healthy", true, [:]),
                                                 ("broken", true, ["vertical_hold": 0.7,
                                                                   "horizontal_hold": 0.9])] {
                    state.glitchEnabled = enabled
                    state.resetGlitch()
                    for (k, v) in values { state.setGlitchValue(k, v) }
                    let url = outDir.appendingPathComponent("\(name)-\(label).\(ext)")
                    try? FileManager.default.removeItem(at: url)
                    do { try await export(url) } catch {
                        print("GLITCHCHK FAIL \(name): \(error)"); failures += 1; return
                    }
                    frames[label] = await firstFrame(url)
                }
                guard let off = frames["off"], let healthy = frames["healthy"], let broken = frames["broken"] else {
                    print("GLITCHCHK FAIL \(name): unreadable output"); failures += 1; return
                }
                let same = meanDiff(off, healthy), changed = meanDiff(off, broken)
                let ok = same < 0.5 && changed > 10
                print(String(format: "GLITCHCHK %@ %@  healthy-vs-off %.2f  broken-vs-off %.2f",
                             ok ? "PASS" : "FAIL", name as NSString, same, changed))
                if !ok { failures += 1 }
            }
            if let vs = state.videoSource {
                await route("video-mp4", ext: "mp4") { url in
                    let s = state.mp4ExportSettings(route: .video, outputURL: url, size: size,
                                                    bitrate: 10_000_000, codec: .h264)
                    try await Mp4Exporter(context: state.context).export(
                        source: vs, paramValues: state.paramValues, settings: s,
                        ntscSettingsJSON: nil, progress: { _ in })
                }
                await route("video-gif", ext: "gif") { url in
                    let s = state.gifExportSettings(outputURL: url, size: (320, size.1 / 2 & ~1))
                    try await GifExporter(context: state.context).exportVideo(
                        source: vs, paramValues: state.paramValues, settings: s,
                        ntscSettingsJSON: nil, progress: { _ in })
                }
            } else if let src = state.sourceTexture {
                await route("png", ext: "png") { url in
                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Swift.Error>) in
                        state.exportPNG(to: url, size: size) { ok in
                            if ok { c.resume() } else { c.resume(throwing: NSError(domain: "glitchcheck", code: 1)) }
                        }
                    }
                }
                state.timelineDuration = 0.5
                state.timelineFPS = 12
                await route("still-mp4", ext: "mp4") { url in
                    let s = state.mp4ExportSettings(route: .still, outputURL: url, size: size,
                                                    bitrate: 10_000_000, codec: .h264)
                    try await Mp4Exporter(context: state.context).exportStill(
                        source: src, totalFrames: state.timelineTotalFrames, fps: state.timelineFPS,
                        paramValues: state.paramValues, settings: s, ntscSettingsJSON: nil,
                        progress: { _ in })
                }
                await route("still-gif", ext: "gif") { url in
                    let s = state.gifExportSettings(outputURL: url, size: (320, size.1 / 2 & ~1))
                    try await GifExporter(context: state.context).exportStill(
                        source: src, totalFrames: 3, paramValues: state.paramValues,
                        settings: s, ntscSettingsJSON: nil, progress: { _ in })
                }
            }
            if state.videoSource == nil && state.sourceTexture == nil {
                print("GLITCHCHK FAIL: no source loaded — nothing was checked")
                failures += 1
            }
            print(failures == 0 ? "GLITCHCHK ALL PASS" : "GLITCHCHK \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        // CRT_EXPORT_TOGGLE_CHECK=<dir>: export every route this source offers
        // with the CRT toggle on and then off — through the same settings
        // builders and methods the Export buttons use — and require the
        // scanlines to be there with it on and gone with it off. (Every route
        // once ignored the toggle; the exporter-level tests in the release
        // gate can't see the buttons' wiring, this can.)
        if let dir = env["CRT_EXPORT_TOGGLE_CHECK"] {
            let outDir = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            state.ntscEnabled = false          // measure the shader alone
            let aspect = Double(state.sourceAspect)
            let size: (width: Int, height: Int) = aspect >= 1
                ? (960, max(64, Int((960 / aspect).rounded())) & ~1)
                : (max(64, Int((960 * aspect).rounded())) & ~1, 960)
            let gifSize = ((size.width / 2) & ~1, (size.height / 2) & ~1)
            var failures = 0

            func firstFrame(_ url: URL) async -> CGImage? {
                if url.pathExtension == "mp4" || url.pathExtension == "mov" {
                    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                    gen.requestedTimeToleranceBefore = .zero
                    gen.requestedTimeToleranceAfter = .zero
                    return try? await gen.image(at: .zero).image
                }
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(src, 0, nil)
            }
            func run(_ route: String, ext: String,
                     export: (URL) async throws -> Void) async {
                var modulation: [Bool: Double] = [:]
                for on in [true, false] {
                    state.shaderEnabled = on
                    let url = outDir.appendingPathComponent("\(route)-\(on ? "on" : "off").\(ext)")
                    try? FileManager.default.removeItem(at: url)
                    do { try await export(url) } catch {
                        print("TOGGLECHK FAIL \(route): \(error)"); failures += 1; return
                    }
                    guard let image = await firstFrame(url) else {
                        print("TOGGLECHK FAIL \(route): unreadable output"); failures += 1; return
                    }
                    modulation[on] = ImageStats.rowModulation(of: image)
                }
                let on = modulation[true] ?? 0, off = modulation[false] ?? 0
                let ok = on > 3 * off && on - off > 2
                print(String(format: "TOGGLECHK %@ %@  scanline modulation on=%.2f off=%.2f",
                             ok ? "PASS" : "FAIL", route as NSString, on, off))
                if !ok { failures += 1 }
            }

            if let vs = state.videoSource {
                await run("video-mp4", ext: "mp4") { url in
                    let s = state.mp4ExportSettings(route: .video, outputURL: url, size: size,
                                                    bitrate: 8_000_000, codec: .h264)
                    try await Mp4Exporter(context: state.context).export(
                        source: vs, paramValues: state.paramValues, settings: s,
                        ntscSettingsJSON: nil, progress: { _ in })
                }
                await run("video-gif", ext: "gif") { url in
                    let s = state.gifExportSettings(outputURL: url, size: gifSize)
                    try await GifExporter(context: state.context).exportVideo(
                        source: vs, paramValues: state.paramValues, settings: s,
                        ntscSettingsJSON: nil, progress: { _ in })
                }
            } else if let src = state.sourceTexture {
                await run("png", ext: "png") { url in
                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Swift.Error>) in
                        state.exportPNG(to: url, size: size) { ok in
                            if ok { c.resume() }
                            else { c.resume(throwing: NSError(domain: "togglecheck", code: 1)) }
                        }
                    }
                }
                state.timelineDuration = 0.5
                state.timelineFPS = 12
                await run("still-mp4", ext: "mp4") { url in
                    let s = state.mp4ExportSettings(route: .still, outputURL: url, size: size,
                                                    bitrate: 8_000_000, codec: .h264)
                    try await Mp4Exporter(context: state.context).exportStill(
                        source: src, totalFrames: state.timelineTotalFrames,
                        fps: state.timelineFPS, paramValues: state.paramValues, settings: s,
                        ntscSettingsJSON: nil, progress: { _ in })
                }
                await run("still-gif", ext: "gif") { url in
                    let s = state.gifExportSettings(outputURL: url, size: gifSize)
                    try await GifExporter(context: state.context).exportStill(
                        source: src, totalFrames: 4, paramValues: state.paramValues,
                        settings: s, ntscSettingsJSON: nil, progress: { _ in })
                }
            }
            if state.videoSource == nil && state.sourceTexture == nil {
                print("TOGGLECHK FAIL: no source loaded — nothing was checked")
                failures += 1
            }
            print(failures == 0 ? "TOGGLECHK ALL PASS" : "TOGGLECHK \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        // CRT_CACHE_CHECK=<out.png>: play the clip so the frame cache fills,
        // then on the second loop dump the composite at a fixed frame,
        // asserting it was served from the cache. The same run with
        // CRT_FRAME_CACHE_OFF=1 dumps the live-rendered frame on loop one;
        // the two files must be byte-identical (compare with `cmp`).
        if let out = env["CRT_CACHE_CHECK"] {
            guard let vs = state.videoSource else { print("CACHECHK FAIL: not a video"); exit(1) }
            let target = vs.totalFrames / 2
            let minLoop = AppState.frameCacheOff ? 0 : 1
            state.compositeDumpRequest = .init(frame: target, minLoop: minLoop, path: out)
            state.togglePlayback()
            var waited = 0
            while state.compositeDumpRequest != nil && waited < 600 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            state.stopPlayback()
            try? await Task.sleep(for: .milliseconds(300))   // let the dump land
            let served = state.dumpServedFromCache
            let ok = served == !AppState.frameCacheOff
            print("CACHECHK \(ok ? "PASS" : "FAIL") frame \(target) loop \(state.playbackLoops) servedFromCache=\(served.map(String.init) ?? "never-dumped") cacheOff=\(AppState.frameCacheOff)")
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

            var settings = state.gifExportSettings(outputURL: URL(fileURLWithPath: out),
                                                   size: (240, 180))
            settings.fps = 8
            let ntscJSON = state.ntscStage?.settingsJSON()
            do {
                try await GifExporter(context: state.context).exportVideo(
                    source: vs, paramValues: state.paramValues, settings: settings,
                    ntscSettingsJSON: ntscJSON,
                    frameParams: { i, total in
                        let t = total > 1 ? Double(i) / Double(total - 1) : 0
                        return (shader: ev.shaderParams(at: t), ntscJSON: ev.ntscJSON(at: t), glitch: nil)
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
        // CRT_SAVE_LOOK=<path>: write the state the app opened with as a look
        // file and quit — diff it against a reference to check the defaults.
        if let path = env["CRT_SAVE_LOOK"] {
            do { try state.saveLook(to: URL(fileURLWithPath: path)); print("SAVED-LOOK \(path)") }
            catch { print("SAVE-LOOK FAIL: \(error)") }
            exit(0)
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
            state.glitchEnabled = true
            state.scrubTimeline(to: 0.25)
            state.setNtscValue("composite_preemphasis", 1.75)
            state.setGlitchValue("vertical_hold", 0.1)
            state.setKeyframeAtPlayhead()
            state.scrubTimeline(to: 0.9)
            state.setNtscValue("composite_preemphasis", 0.5)
            state.setGlitchValue("vertical_hold", 0.8)
            state.setKeyframeAtPlayhead()
            state.setGlitchValue("ghost_level", -0.4)
            state.setKeyframeEasing(id: state.timelineKeys[0].id, .easeInOut)
            let before = state.timelineKeys
            let firstParam = state.paramDescriptors.first?.name
            let beforeShader = firstParam.flatMap { before[0].shaderParams[$0] }

            let url = URL(fileURLWithPath: path)
            do { try state.saveLook(to: url) } catch {
                print("PRESET FAIL save: \(error)"); exit(1)
            }
            // Wipe, so anything that survives really came from the file.
            state.glitchEnabled = false
            state.resetGlitch()
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
                    check("key \(i) glitch value",
                          k.glitchValues["vertical_hold"] == before[i].glitchValues["vertical_hold"],
                          "\(k.glitchValues["vertical_hold"] ?? -1) vs \(before[i].glitchValues["vertical_hold"] ?? -1)")
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
            check("glitch stage re-enabled", state.glitchEnabled)
            // The ghost edit came while parked on the second key, so auto-key
            // wrote it there; loading reopens the timeline at the first key,
            // whose snapshot the knobs then show.
            check("auto-key captured the glitch edit",
                  state.timelineKeys.last?.glitchValues["ghost_level"] == -0.4,
                  "\(state.timelineKeys.last?.glitchValues["ghost_level"] ?? 99)")
            check("knobs show the first key after load",
                  state.glitchSettings["vertical_hold"] == 0.1 && state.glitchSettings["ghost_level"] == 0,
                  "vhold \(state.glitchSettings["vertical_hold"]) ghost \(state.glitchSettings["ghost_level"])")
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
        // Compare starts off, so placing the divider also turns it on.
        if let cx = env["CRT_COMPARE_X"].flatMap(Float.init) {
            state.compareEnabled = true
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
            // diamond does — makes playhead/diamond centering measurable.
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
                    // Does a click at this view's center reach the control
                    // underneath, or does the tooltip overlay swallow it?
                    var hitClass = "?"
                    if let cv = v.window?.contentView {
                        let center = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: cv)
                        hitClass = cv.hitTest(center).map { "\(type(of: $0))" } ?? "nil"
                    }
                    print("TOOLTIP [\(type(of: v))] frame=\(v.frame.integral) hitTestAtCenter=\(hitClass) :: \(t.prefix(40))")
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
        let settings = state.gifExportSettings(outputURL: out, size: (w, h))
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
                        return (shader: e.shaderParams(at: t), ntscJSON: e.ntscJSON(at: t), glitch: nil)
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
        let settings = state.mp4ExportSettings(route: .still, outputURL: out,
                                               size: (960, 720), bitrate: 8_000_000,
                                               codec: .h264)
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
                    return (shader: ev.shaderParams(at: t), ntscJSON: ev.ntscJSON(at: t), glitch: nil)
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
                showHowlaround = true
            } label: {
                Label("Screen Loop", systemImage: "camera.viewfinder")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(state.sourceTexture == nil && state.videoSource == nil || state.exportWorking)
            .sheet(isPresented: $showHowlaround) {
                HowlaroundPanel().environment(state)
            }
            .help("Screen Loop: point a camcorder at the TV that's showing its own picture — video feedback, a tunnel of copies with your look on every pass")

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
                GlitchPanel()
                Divider()
                ShaderPanel()
            }
            .padding(16)
        }
    }
}
