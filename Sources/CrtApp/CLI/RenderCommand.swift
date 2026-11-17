import Foundation
import ImageIO
import CoreGraphics
import CrtCore

/// `NTSCRT render <source> -o <file> [options]`: the Export button, from
/// the command line. See `CLIHelp.text` for the options.
@MainActor
enum RenderCommand {
    struct Request {
        var source: String?
        var output: String?
        var settings: [String: Any] = [:]
        var format: String?
        var longEdge: Int?
        var gifWidth: Int?
        var gifFPS: Int?
        var quality: String?
        var snap = false
        var loops: Int?
        /// PNG: the frames to take, in seconds.
        var times: [Double] = []
        var saveLook: String?
        var dryRun = false
        /// PNG: magnify like the preview zoomed in (1–12×), at this point.
        var zoom: Double = 1
        var zoomAt: (x: Double, y: Double) = (0.5, 0.5)
    }

    static func run(_ args: [String]) async -> Int32 {
        let started = Date()
        do {
            let request = try parse(args)
            let result = try await render(request)
            var out = result
            out["ok"] = true
            out["elapsed"] = CLI.decimal(Date().timeIntervalSince(started), places: 1)
            CLI.emitJSON(out)
            return 0
        } catch let e as CLIError {
            CLI.emitJSON(["ok": false, "error": e.message])
            CLI.log("NTSCRT: \(e.message)")
            return e.code
        } catch {
            CLI.emitJSON(["ok": false, "error": error.localizedDescription])
            CLI.log("NTSCRT: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: - parsing

    static func parse(_ args: [String]) throws -> Request {
        var r = Request()
        var flagSettings: [String: Any] = [:]
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw CLIError(message: "\(flag) needs a value.") }
            return args[i]
        }
        func stage(_ key: String) -> [String: Any] { flagSettings[key] as? [String: Any] ?? [:] }
        func setStage(_ key: String, _ field: String, _ v: Any) {
            var d = stage(key); d[field] = v; flagSettings[key] = d
        }
        func mergeValues(_ key: String, _ field: String, _ pairs: String) throws {
            var d = stage(key)
            var values = d[field] as? [String: Any] ?? [:]
            for (k, v) in try keyValues(pairs) { values[k] = v }
            d[field] = values
            flagSettings[key] = d
        }
        /// "on" / "off" for a stage's switch, else (for digital and crt)
        /// a format or preset.
        func switchOrName(_ key: String, _ raw: String, nameField: String?) throws {
            if LookSettings.isOn(raw) || LookSettings.isOff(raw) {
                setStage(key, "enabled", LookSettings.isOn(raw))
            } else if let nameField {
                setStage(key, nameField, raw)
            } else {
                throw CLIError(message: "--\(key) takes on or off.")
            }
        }

        while i < args.count {
            let a = args[i]
            switch a {
            case "-o", "--out", "--output": r.output = try value(a)
            case "--settings":
                let raw = try value(a)
                r.settings = try parseSettingsJSON(raw)
            case "--look": flagSettings["look"] = try value(a)
            case "--crop": flagSettings["crop"] = try value(a)
            case "--downscale":
                let v = try value(a)
                if LookSettings.isOff(v) || LookSettings.isOn(v) { setStage("downscale", "enabled", LookSettings.isOn(v)) }
                else if let w = Double(v) { setStage("downscale", "width", w) }
                else { throw CLIError(message: "--downscale takes a width in pixels, or off.") }
            case "--downscale-method": setStage("downscale", "method", try value(a))
            case "--digital": try switchOrName("digital", try value(a), nameField: "format")
            case "--digital-set": try mergeValues("digital", "values", try value(a))
            case "--ntsc": try switchOrName("ntsc", try value(a), nameField: nil)
            case "--ntsc-set": try mergeValues("ntsc", "settings", try value(a))
            case "--glitch": try switchOrName("glitch", try value(a), nameField: nil)
            case "--glitch-set": try mergeValues("glitch", "values", try value(a))
            case "--vcr": try switchOrName("vcr", try value(a), nameField: nil)
            case "--vcr-set": try mergeValues("vcr", "values", try value(a))
            case "--tape": setStage("vcr", "tape", try value(a))
            case "--deck": setStage("vcr", "deck", try value(a))
            case "--crt": try switchOrName("crt", try value(a), nameField: "preset")
            case "--crt-set": try mergeValues("crt", "params", try value(a))
            case "--duration":
                guard let d = Double(try value(a)) else { throw CLIError(message: "--duration takes seconds.") }
                setStage("timeline", "duration", d)
            case "--fps":
                guard let f = Double(try value(a)) else { throw CLIError(message: "--fps takes a number.") }
                setStage("timeline", "fps", f)
            case "--format": r.format = try value(a).lowercased()
            case "--long-edge", "--size": r.longEdge = try int(try value(a), a)
            case "--gif-width": r.gifWidth = try int(try value(a), a)
            case "--gif-fps": r.gifFPS = try int(try value(a), a)
            case "--quality": r.quality = try value(a).lowercased()
            case "--snap": r.snap = true
            case "--loops": r.loops = try int(try value(a), a)
            case "--time", "--times", "--at":
                r.times = try value(a).split(separator: ",").map {
                    guard let t = Double($0.trimmingCharacters(in: .whitespaces)), t >= 0 else {
                        throw CLIError(message: "--time takes seconds, e.g. 0,1.5,3.")
                    }
                    return t
                }
            case "--save-look": r.saveLook = try value(a)
            case "--zoom":
                guard let z = Double(try value(a)), z >= 1 else { throw CLIError(message: "--zoom takes a magnification from 1 to 12.") }
                r.zoom = min(12, z)
            case "--zoom-at":
                let xy = try value(a).split(separator: ",").compactMap { Double($0) }
                guard xy.count == 2 else { throw CLIError(message: "--zoom-at takes x,y from 0 to 1 (0.5,0.5 is the center).") }
                r.zoomAt = (min(1, max(0, xy[0])), min(1, max(0, xy[1])))
            case "--dry-run": r.dryRun = true
            default:
                if a.hasPrefix("-") { throw CLIError(message: "Unknown option \(a). Run `NTSCRT help`.") }
                guard r.source == nil else { throw CLIError(message: "One source at a time (got \(r.source!) and \(a)).") }
                r.source = a
            }
            i += 1
        }
        // Flags win over --settings, stage by stage.
        for (k, v) in flagSettings {
            if var base = r.settings[k] as? [String: Any], let add = v as? [String: Any] {
                for (field, fv) in add {
                    if var inner = base[field] as? [String: Any], let addInner = fv as? [String: Any] {
                        inner.merge(addInner) { _, new in new }
                        base[field] = inner
                    } else {
                        base[field] = fv
                    }
                }
                r.settings[k] = base
            } else {
                r.settings[k] = v
            }
        }
        if r.output == nil && r.saveLook == nil && !r.dryRun {
            throw CLIError(message: "Say where to write it: -o <file> (.mp4, .mov, .gif or .png), or --save-look <file.json>.")
        }
        if r.source == nil && (r.output != nil || r.dryRun) {
            throw CLIError(message: "Give a source image or video: NTSCRT render <file> -o <out>.")
        }
        return r
    }

    static func parseSettingsJSON(_ raw: String) throws -> [String: Any] {
        var text = raw
        if raw.hasPrefix("@") || (!raw.trimmingCharacters(in: .whitespaces).hasPrefix("{")) {
            let path = ((raw.hasPrefix("@") ? String(raw.dropFirst()) : raw) as NSString).expandingTildeInPath
            guard let data = FileManager.default.contents(atPath: path) else {
                throw CLIError(message: "--settings: no such file \(path).")
            }
            text = String(decoding: data, as: UTF8.self)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CLIError(message: "--settings isn't a JSON object.")
        }
        return obj
    }

    /// "a=1,b=on,tape_speed=EP" → typed values.
    static func keyValues(_ s: String) throws -> [(String, Any)] {
        try s.split(separator: ",").map { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].isEmpty else { throw CLIError(message: "Expected key=value, got \"\(pair)\".") }
            let raw = kv[1]
            if let d = Double(raw) { return (kv[0], d) }
            if raw.lowercased() == "true" || raw.lowercased() == "on" { return (kv[0], true) }
            if raw.lowercased() == "false" || raw.lowercased() == "off" { return (kv[0], false) }
            return (kv[0], raw)
        }
    }

    static func int(_ s: String, _ flag: String) throws -> Int {
        guard let n = Int(s), n > 0 else { throw CLIError(message: "\(flag) takes a whole number.") }
        return n
    }

    // MARK: - rendering

    static let formats: [String: ExportFormat] = [
        "h264": .h264, "mp4": .h264, "hevc": .hevc, "h265": .hevc,
        "prores": .prores422, "prores422": .prores422, "mov": .prores422,
        "prores-hq": .prores422HQ, "prores422hq": .prores422HQ, "gif": .gif,
    ]
    static let qualities: [String: ExportQuality] = [
        "standard": .standard, "high": .high, "very-high": .veryHigh, "veryhigh": .veryHigh, "maximum": .maximum,
    ]

    static func render(_ r: Request) async throws -> [String: Any] {
        let state = try Session.makeState()
        if let source = r.source { try await Session.load(source, into: state) }
        var looks = LookSettings()
        try await looks.apply(r.settings, to: state)
        for w in looks.warnings { CLI.log("warning: \(w)") }

        var result: [String: Any] = ["look": Summary.stages(state)]
        if !looks.warnings.isEmpty { result["warnings"] = looks.warnings }

        if let path = r.saveLook {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do { try state.saveLook(to: url) }
            catch { throw CLIError(message: "Couldn't save the look: \(error.localizedDescription)", code: 1) }
            result["savedLook"] = url.path
        }
        guard let outPath = r.output ?? (r.dryRun ? "/dev/null/preview.mp4" : nil) else { return result }
        let url = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)

        // Format: --format, else the extension.
        let ext = url.pathExtension.lowercased()
        let png = r.format == "png" || (r.format == nil && ext == "png")
        if !png {
            let key = r.format ?? ext
            guard let f = formats[key] else {
                throw CLIError(message: "Can't tell the format from \"\(url.lastPathComponent)\": use .mp4, .mov, .gif or .png, or --format h264|hevc|prores|prores-hq|gif|png.")
            }
            state.exportFormat = f
        }
        if let n = r.longEdge { state.exportLongEdge = min(8192, max(64, n)) }
        if let n = r.gifWidth { state.gifWidth = min(2048, max(64, n)) }
        if let n = r.gifFPS { state.gifFPS = min(50, max(1, n)) }
        if let q = r.quality {
            guard let quality = qualities[q] else { throw CLIError(message: "--quality is standard, high, very-high or maximum.") }
            state.exportQuality = quality
        }
        state.snapExportToScanlineGrid = r.snap
        if let n = r.loops { state.exportLoopCount = min(100, n) }

        if png {
            return try await renderPNGs(state, url: url, times: r.times.isEmpty ? [0] : r.times,
                                        zoom: r.zoom, zoomAt: r.zoomAt, dryRun: r.dryRun, into: result)
        }
        let size = state.movieExportSize
        let (frames, fps) = state.movieExportFrames
        let passes = 1 + Int(state.glitchSettings["tape_generation"].rounded()) * (state.vcrEnabled ? 1 : 0)
        result["plan"] = ["route": state.movieRoute.rawValue, "format": state.exportFormat.rawValue,
                          "width": size.width, "height": size.height, "frames": frames, "fps": CLI.decimal(fps, places: 3),
                          "seconds": CLI.decimal(Double(frames) / max(1, fps)),
                          "vcrPasses": state.vcrEnabled ? passes : 0] as [String: Any]
        if r.dryRun { return result }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        state.exportInProgress = true
        let progress = ProgressReporter()
        let done = try await state.exportMovie(to: url) { p in progress.report(p) }
        state.exportInProgress = false
        result["outputs"] = [output(url, done.width, done.height, frames: done.frames, fps: done.fps)]
        return result
    }

    private static func output(_ url: URL, _ w: Int, _ h: Int, frames: Int? = nil, fps: Double? = nil,
                               time: Double? = nil) -> [String: Any] {
        var o: [String: Any] = ["path": url.path, "width": w, "height": h]
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        o["bytes"] = bytes ?? 0
        if let frames, let fps {
            o["frames"] = frames
            o["seconds"] = CLI.decimal(Double(frames) / max(1, fps))
            o["fps"] = CLI.decimal(fps, places: 3)
        }
        if let time { o["time"] = CLI.decimal(time, places: 3) }
        return o
    }

    /// Stills of the look at the given times. History counts — clogs build
    /// up, the tracking hunts, creases pass — so each is the frame the
    /// export would have at that time, simulated up to it.
    static func renderPNGs(_ state: AppState, url: URL, times: [Double],
                           zoom: Double = 1, zoomAt: (x: Double, y: Double) = (0.5, 0.5),
                           dryRun: Bool, into base: [String: Any]) async throws -> [String: Any] {
        var result = base
        let size = state.exportVideoSize
        result["plan"] = ["route": "png", "width": size.width, "height": size.height, "times": times] as [String: Any]
        if dryRun { return result }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var outputs: [[String: Any]] = []
        let stem = url.deletingPathExtension().lastPathComponent
        for t in times {
            let file = times.count == 1 ? url
                : url.deletingLastPathComponent().appendingPathComponent(String(format: "%@ %.2fs.png", stem, t))
            let at = try await seek(state, to: t)
            guard await state.exportPNG(to: file, size: size) else {
                throw CLIError(message: "Rendering the frame at \(t) s failed: \(state.exportStatus)", code: 1)
            }
            if zoom > 1.001 { try magnify(file, zoom: zoom, at: zoomAt) }
            outputs.append(output(file, size.width, size.height, time: at))
        }
        result["outputs"] = outputs
        return result
    }

    /// The preview zoomed in, as Export viewport saves it: the CRT render
    /// cut to 1/zoom around the point and enlarged pixel for pixel, so the
    /// scanlines and the phosphor mask show close up.
    static func magnify(_ file: URL, zoom: Double, at p: (x: Double, y: Double)) throws {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CLIError(message: "Couldn't reopen \(file.lastPathComponent) to zoom it.", code: 1)
        }
        let w = image.width, h = image.height
        let cw = max(1, Int((Double(w) / zoom).rounded())), ch = max(1, Int((Double(h) / zoom).rounded()))
        let x0 = min(w - cw, max(0, Int(p.x * Double(w)) - cw / 2))
        let y0 = min(h - ch, max(0, Int(p.y * Double(h)) - ch / 2))
        guard let cut = image.cropping(to: CGRect(x: x0, y: y0, width: cw, height: ch)),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CLIError(message: "Couldn't zoom \(file.lastPathComponent).", code: 1)
        }
        ctx.interpolationQuality = .none
        ctx.draw(cut, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw CLIError(message: "Couldn't zoom \(file.lastPathComponent).", code: 1) }
        try writePNG(out, to: file)
    }

    /// Put the playhead at `t` seconds; returns the time it landed on.
    static func seek(_ state: AppState, to t: Double) async throws -> Double {
        if let vs = state.videoSource {
            let fps = Double(max(1, vs.frameRate))
            let frame = min(vs.totalFrames - 1, max(0, Int((t * fps).rounded())))
            if state.timelineEnabled {
                state.scrubTimeline(to: vs.totalFrames > 1 ? Double(frame) / Double(vs.totalFrames - 1) : 0)
            } else if frame != state.currentFrameIndex {
                let version = state.sourceVersion
                state.currentFrameIndex = frame
                try await Session.waitUntil("frame \(frame)", seconds: 30) { state.sourceVersion != version && state.sourceTexture != nil }
            }
            try await Session.waitUntil("frame \(frame)", seconds: 30) { state.sourceTexture != nil }
            return Double(frame) / fps
        }
        // A still: its time runs on the timeline (keyframes, if the look
        // has any, are spread over the timeline's length).
        if !state.hasTimelineKeys && t > state.timelineDuration { state.timelineDuration = t }
        state.timelineEnabled = true
        let total = state.timelineTotalFrames
        let frame = min(total - 1, max(0, Int((t * Double(state.timelineFPS)).rounded())))
        state.scrubTimeline(to: total > 1 ? Double(frame) / Double(total - 1) : 0)
        state.setFrameCounter(frame + 1)
        return Double(frame) / Double(max(1, state.timelineFPS))
    }
}

/// Progress lines on stderr: {"progress":0.42,"eta":12.5}, at most a few a
/// second.
final class ProgressReporter: @unchecked Sendable {
    private let start = Date()
    private var last = Date.distantPast
    private var finished = false
    private let lock = NSLock()

    func report(_ p: Double) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard !finished, now.timeIntervalSince(last) > 0.25 || p >= 1 else { return }
        last = now
        finished = p >= 1
        let elapsed = now.timeIntervalSince(start)
        var line: [String: Any] = ["progress": CLI.decimal(p, places: 3)]
        if p > 0.02 { line["eta"] = CLI.decimal(elapsed / p * (1 - p), places: 1) }
        if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
            FileHandle.standardError.write(data + Data("\n".utf8))
        }
    }
}

/// What a look does, in the panels' words — so a caller can check it got
/// what it asked for.
@MainActor
enum Summary {
    static func stages(_ s: AppState) -> [String: Any] {
        var out: [String: Any] = [:]
        out["crop"] = s.cropEnabled ? s.cropRatio.label : "off"
        out["digital"] = s.digitalEnabled ? (s.digitalFormat?.name ?? "custom") : "off"
        out["ntsc"] = s.ntscEnabled && s.ntscAvailable ? "on" : "off"
        if let src = s.sourcePixelSize { out["source"] = "\(src.width)×\(src.height)" }
        if s.downscaleEnabled {
            let method = LookSettings.downscaleMethods.first { $0.value == s.downscaleMethod }?.key ?? s.downscaleMethod.rawValue
            out["downscale"] = "\(s.downscaleWidth) wide, \(method), \(s.chainInputSize.height) lines"
        } else {
            out["downscale"] = "off (\(s.chainInputSize.height) lines)"
        }
        let g = s.glitchSettings
        out["glitch"] = s.glitchEnabled
            ? (GlitchParam.controls(in: .reception).allSatisfy { abs(g[$0.id] - $0.defaultValue) < 1e-9 } ? "on (healthy)" : "on")
            : "off"
        if s.vcrEnabled {
            let names = { (id: String) -> String in
                if case .choice(let o)? = GlitchParam.byID[id]?.kind { return o[min(o.count - 1, max(0, Int(g[id].rounded())))] }
                return ""
            }
            out["vcr"] = [
                "tape": VcrCondition.matching(VcrCondition.tapes, keys: VcrCondition.tapeKeys, in: g.values)?.name ?? "custom",
                "deck": VcrCondition.matching(VcrCondition.decks, keys: VcrCondition.deckKeys, in: g.values)?.name ?? "custom",
                "recordedAt": names("tape_speed"),
                "generation": names("tape_generation"),
            ]
        } else {
            out["vcr"] = "off"
        }
        out["crt"] = s.shaderEnabled ? s.selectedPreset.id : "off"
        if s.hasTimelineKeys { out["keyframes"] = s.timelineKeys.count }
        return out
    }
}
