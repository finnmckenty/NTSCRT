import Foundation
import CrtAppBridge
import CrtCore

/// The app, started without a window, with a source loaded.
@MainActor
enum Session {
    static func makeState() throws -> AppState {
        do {
            try LRShaderChain.loadLibrary(Paths.librashaderDylib().path)
            if let ntsc = Paths.ntscrsDylib() { try? NTSCFilter.loadLibrary(ntsc.path) }
            let context = try MetalContext()
            return try AppState(context: context, presetsRoot: Paths.slangShadersRoot())
        } catch {
            throw CLIError(message: "NTSCRT couldn't start its renderer: \(error.localizedDescription)", code: 1)
        }
    }

    /// Load an image or video and wait until its first frame is up.
    static func load(_ path: String, into state: AppState) async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(message: "No such file: \(url.path)")
        }
        state.sourceURL = url
        try await waitUntil("the source to load", seconds: 60) {
            if let e = state.sourceError { throw CLIError(message: "Couldn't open \(url.lastPathComponent): \(e)") }
            return state.sourceTexture != nil && state.sourceKind != nil
        }
        try await waitForChain(state)
    }

    static func waitForChain(_ state: AppState) async throws {
        try await waitUntil("the CRT shader to compile", seconds: 60) {
            if let e = state.chainError { throw CLIError(message: "The CRT shader failed: \(e)", code: 1) }
            return state.chain != nil
        }
    }

    static func waitUntil(_ what: String, seconds: Double,
                          _ ready: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while try !ready() {
            if Date() > deadline { throw CLIError(message: "Timed out waiting for \(what).", code: 1) }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A look, described as JSON: the shape `--settings` takes and the MCP
/// server's tools pass. Every key is optional; what's left out stays as
/// the chosen look (or the app's defaults) has it.
///
///     {"look": "90s VHS bootleg",
///      "crop": "9:16",
///      "digital": {"format": "minidv", "values": {"data_loss": 0.2}},
///      "ntsc": {"enabled": true, "settings": {"luma_smear": 0.4}},
///      "downscale": {"width": 320, "method": "chunky"},
///      "glitch": {"values": {"vertical_hold": 0.3}},
///      "vcr": {"tape": "Moldy", "deck": "Dirty heads", "values": {"tape_speed": "EP"}},
///      "crt": {"preset": "royale", "params": {"…": 1.0}},
///      "timeline": {"duration": 4, "fps": 30}}
///
/// A stage can also be just "on", "off", or (for digital and crt) a format
/// or preset id. Setting any VCR value switches the VCR on; the other
/// stages keep their switch unless "enabled" says otherwise.
@MainActor
struct LookSettings {
    var warnings: [String] = []

    static let stageOrder = ["look", "crop", "downscale", "digital", "ntsc", "glitch", "vcr", "crt", "timeline", "keyframes", "description"]

    mutating func apply(_ settings: [String: Any], to state: AppState) async throws {
        let unknown = Set(settings.keys).subtracting(Self.stageOrder)
        if !unknown.isEmpty {
            throw CLIError(message: "Unknown setting \(unknown.sorted().joined(separator: ", ")). Known: \(Self.stageOrder.joined(separator: ", ")).")
        }
        if let look = settings["look"] { try applyLook(look, state) }
        // A look's description no longer fits once it's been changed.
        if !Set(settings.keys).subtracting(["look", "description", "timeline"]).isEmpty { state.lookDescription = nil }
        if let d = settings["description"] as? String { state.lookDescription = d }
        if let v = settings["crop"] { try applyCrop(v, state) }
        if let v = settings["downscale"] { try applyDownscale(v, state) }
        if let v = settings["digital"] { try applyDigital(v, state) }
        if let v = settings["ntsc"] { try applyNtsc(v, state) }
        if let v = settings["glitch"] { try applyGlitch(v, state) }
        if let v = settings["vcr"] { try applyVcr(v, state) }
        if let v = settings["crt"] { try applyCrt(v, state) }
        if let v = settings["timeline"] { try applyTimeline(v, state) }
        try await Session.waitForChain(state)
        if let v = settings["keyframes"] {
            try applyKeyframes(v, explicitDuration: (settings["timeline"] as? [String: Any])?["duration"] != nil, state)
        }
    }

    // MARK: looks

    static func builtInLooks() -> [BuiltInPreset] { BuiltInPreset.discover() }

    static func lookURL(_ name: String) throws -> URL {
        let expanded = (name as NSString).expandingTildeInPath
        if name.hasSuffix(".json") || name.contains("/") {
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw CLIError(message: "No such look file: \(expanded)")
            }
            return URL(fileURLWithPath: expanded)
        }
        let looks = builtInLooks()
        if let hit = looks.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return hit.url }
        throw CLIError(message: "No built-in look named \"\(name)\". Run `NTSCRT looks` for the list (\(looks.map(\.name).joined(separator: ", "))).")
    }

    private func applyLook(_ v: Any, _ state: AppState) throws {
        guard let name = v as? String else { throw CLIError(message: "\"look\" takes a look name or a .json path.") }
        do { try state.loadLook(from: Self.lookURL(name)) }
        catch let e as CLIError { throw e }
        catch { throw CLIError(message: "Couldn't load the look \(name): \(error.localizedDescription)") }
    }

    // MARK: crop and downscale

    private func applyCrop(_ v: Any, _ state: AppState) throws {
        if let s = v as? String {
            if Self.isOff(s) { state.cropEnabled = false; return }
            // "9:16", "9:16@0.2,0.7", each optionally "*1.5" (zoomed in).
            let scaled = s.split(separator: "*")
            let placed = scaled[0].split(separator: "@")
            guard let ratio = SourceCrop.Ratio(label: String(placed[0])) else {
                throw CLIError(message: "Crop \"\(s)\": expected a ratio like 9:16, optionally @x,y and *zoom.")
            }
            let at = placed.count > 1 ? placed[1].split(separator: ",").compactMap { Double($0) } : []
            let zoom = scaled.count > 1 ? Double(scaled[1]) ?? 1 : 1
            setCrop(state, ratio, at.first ?? 0.5, at.last ?? 0.5, zoom)
        } else if let d = v as? [String: Any] {
            if (d["enabled"] as? Bool) == false { state.cropEnabled = false; return }
            guard let label = d["ratio"] as? String, let ratio = SourceCrop.Ratio(label: label) else {
                throw CLIError(message: "Crop needs a \"ratio\" like \"9:16\".")
            }
            setCrop(state, ratio, Self.number(d["x"]) ?? 0.5, Self.number(d["y"]) ?? 0.5, Self.number(d["zoom"]) ?? 1)
        } else {
            throw CLIError(message: "\"crop\" takes \"off\", a ratio like \"9:16\", or {ratio, x, y, zoom}.")
        }
    }

    private func setCrop(_ state: AppState, _ ratio: SourceCrop.Ratio, _ x: Double, _ y: Double, _ zoom: Double) {
        state.setCrop(SourceCrop(ratio: ratio, x: min(1, max(0, x)), y: min(1, max(0, y)),
                                 scale: min(SourceCrop.maxScale, max(1, zoom))))
        state.cropEnabled = true
    }

    static let downscaleMethods: [String: DownscaleMethod] = ["chunky": .nearest, "smooth": .area]

    private func applyDownscale(_ v: Any, _ state: AppState) throws {
        if let s = v as? String, Self.isOff(s) { state.downscaleEnabled = false; return }
        if let s = v as? String, Self.isOn(s) { state.downscaleEnabled = true; return }
        if let w = Self.number(v) { setDownscaleWidth(state, w); return }
        guard let d = v as? [String: Any] else {
            throw CLIError(message: "\"downscale\" takes \"off\", a width in pixels, or {width, method}.")
        }
        if let w = Self.number(d["width"]) { setDownscaleWidth(state, w) }
        if let m = d["method"] as? String {
            guard let method = Self.downscaleMethods[m.lowercased()] ?? DownscaleMethod(rawValue: m) else {
                throw CLIError(message: "Downscale method \"\(m)\": use chunky or smooth.")
            }
            state.downscaleMethod = method
        }
        if let e = d["enabled"] as? Bool { state.downscaleEnabled = e }
    }

    private func setDownscaleWidth(_ state: AppState, _ w: Double) {
        state.downscaleWidth = Int(min(4096, max(16, w.rounded())))
        state.downscalePreset = "Custom"
        state.downscaleEnabled = true
    }

    // MARK: digital video

    static func digitalFormat(_ s: String) -> DigitalFormat? {
        DigitalFormat.byID[s.lowercased()]
            ?? DigitalFormat.all.first { $0.name.caseInsensitiveCompare(s) == .orderedSame }
    }

    private mutating func applyDigital(_ v: Any, _ state: AppState) throws {
        var dict: [String: Any] = [:]
        if let s = v as? String {
            if Self.isOff(s) { state.setDigitalEnabled(false); return }
            if Self.isOn(s) { state.setDigitalEnabled(true); return }
            dict["format"] = s
        } else if let d = v as? [String: Any] {
            dict = d
        } else {
            throw CLIError(message: "\"digital\" takes \"on\", \"off\", a format id, or {format, values, enabled}.")
        }
        if let f = dict["format"] as? String {
            guard let format = Self.digitalFormat(f) else {
                throw CLIError(message: "No Digital video format \"\(f)\". Formats: \(DigitalFormat.all.map(\.id).joined(separator: ", ")).")
            }
            state.applyDigitalFormat(format)
        }
        try setDigitalValues(dict["values"], state)
        let enabled = (dict["enabled"] as? Bool) ?? true
        state.setDigitalEnabled(enabled)
    }

    private mutating func setDigitalValues(_ raw: Any?, _ state: AppState) throws {
        guard let raw else { return }
        guard let values = raw as? [String: Any] else { throw CLIError(message: "Digital video \"values\" is an object of control: value.") }
        for (key, raw) in values {
            guard let p = DigitalParam.byID[key] else {
                throw CLIError(message: "No Digital video control \"\(key)\". Controls: \(DigitalParam.all.map(\.id).joined(separator: ", ")).")
            }
            let value: Double
            switch p.kind {
            case .choice(let options):
                value = try Self.choiceIndex(raw, options, "digital \(key)")
            case .slider(let lo, let hi, _, _):
                value = try clamped(raw, lo, hi, "digital \(key)")
            }
            state.setDigitalValue(key, value)
        }
    }

    // MARK: NTSC (ntsc-rs)

    /// Every NTSC setting by key, groups' switches included — retired ones
    /// left out (the VCR replaces them).
    static func ntscSettings(_ state: AppState) -> [String: NtscSetting] {
        var out: [String: NtscSetting] = [:]
        func walk(_ list: [NtscSetting]) {
            for s in list {
                switch s.kind {
                case .section(let kids): walk(kids)
                case .group(let kids):
                    if !NtscSetting.retiredVHS.contains(s.name) { out[s.name] = s; walk(kids) }
                default: out[s.name] = s
                }
            }
        }
        walk(state.ntscDescriptors)
        return out
    }

    private mutating func applyNtsc(_ v: Any, _ state: AppState) throws {
        if let s = v as? String {
            guard Self.isOn(s) || Self.isOff(s) else { throw CLIError(message: "\"ntsc\" takes \"on\", \"off\", or {enabled, settings}.") }
            state.ntscEnabled = Self.isOn(s)
            return
        }
        guard let d = v as? [String: Any] else { throw CLIError(message: "\"ntsc\" takes \"on\", \"off\", or {enabled, settings}.") }
        try setNtscSettings(d["settings"], state)
        state.ntscEnabled = (d["enabled"] as? Bool) ?? state.ntscEnabled
    }

    private mutating func setNtscSettings(_ raw: Any?, _ state: AppState) throws {
        guard let raw else { return }
        guard let settings = raw as? [String: Any] else { throw CLIError(message: "NTSC \"settings\" is an object of setting: value.") }
        if !settings.isEmpty {
            guard state.ntscAvailable else { throw CLIError(message: "The NTSC stage isn't available (ntscrs_capi.dylib not found).", code: 1) }
            let known = Self.ntscSettings(state)
            for (key, raw) in settings {
                guard let s = known[key] else {
                    let retired = Self.retiredNtscKeys(state).contains(key)
                    throw CLIError(message: retired
                        ? "NTSC \"\(key)\" is ntsc-rs's old VHS filter, retired for the VCR stage: use \"vcr\" instead."
                        : "No NTSC setting \"\(key)\". Run `NTSCRT describe ntsc` for the list.")
                }
                state.setNtscValue(key, try ntscValue(raw, s))
            }
        }
    }

    static func retiredNtscKeys(_ state: AppState) -> Set<String> {
        var out = Set<String>()
        func walk(_ list: [NtscSetting], _ inside: Bool) {
            for s in list {
                let retired = inside || NtscSetting.retiredVHS.contains(s.name)
                if retired { out.insert(s.name) }
                switch s.kind {
                case .section(let kids), .group(let kids): walk(kids, retired)
                default: break
                }
            }
        }
        walk(state.ntscDescriptors, false)
        return out
    }

    private mutating func ntscValue(_ raw: Any, _ s: NtscSetting) throws -> Any {
        switch s.kind {
        case .boolean, .group:
            guard let b = Self.bool(raw) else { throw CLIError(message: "NTSC \(s.name) is on/off.") }
            return b
        case .percentage:
            return try clamped(raw, 0, 1, "ntsc \(s.name)")
        case .float(let lo, let hi, _):
            return try clamped(raw, lo, hi, "ntsc \(s.name)")
        case .int(let lo, let hi):
            return Int(try clamped(raw, Double(lo), Double(hi), "ntsc \(s.name)").rounded())
        case .enumeration(let options):
            if let name = raw as? String,
               let hit = options.first(where: { $0.label.caseInsensitiveCompare(name) == .orderedSame }) {
                return hit.index
            }
            if let n = Self.number(raw), options.contains(where: { $0.index == Int(n) }) { return Int(n) }
            throw CLIError(message: "NTSC \(s.name) is one of: \(options.map(\.label).joined(separator: ", ")).")
        case .section:
            throw CLIError(message: "NTSC \(s.name) is a heading, not a setting.")
        }
    }

    // MARK: glitch and VCR (one stage, two panels)

    private mutating func applyGlitch(_ v: Any, _ state: AppState) throws {
        if let s = v as? String {
            guard Self.isOn(s) || Self.isOff(s) else { throw CLIError(message: "\"glitch\" takes \"on\", \"off\", or {enabled, values}.") }
            state.glitchEnabled = Self.isOn(s)
            return
        }
        guard let d = v as? [String: Any] else { throw CLIError(message: "\"glitch\" takes \"on\", \"off\", or {enabled, values}.") }
        try setGlitchValues(d["values"], groups: [.reception], panel: "Glitch", state)
        state.glitchEnabled = (d["enabled"] as? Bool) ?? true
    }

    static func vcrCondition(_ name: String, in list: [VcrCondition]) -> VcrCondition? {
        list.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private mutating func applyVcr(_ v: Any, _ state: AppState) throws {
        if let s = v as? String {
            guard Self.isOn(s) || Self.isOff(s) else { throw CLIError(message: "\"vcr\" takes \"on\", \"off\", or {enabled, tape, deck, values}.") }
            state.vcrEnabled = Self.isOn(s)
            return
        }
        guard let d = v as? [String: Any] else { throw CLIError(message: "\"vcr\" takes \"on\", \"off\", or {enabled, tape, deck, values}.") }
        if let t = d["tape"] as? String {
            guard let c = Self.vcrCondition(t, in: VcrCondition.tapes) else {
                throw CLIError(message: "No tape \"\(t)\". Tapes: \(VcrCondition.tapes.map(\.name).joined(separator: ", ")).")
            }
            state.applyVcrCondition(c, keys: VcrCondition.tapeKeys)
        }
        if let k = d["deck"] as? String {
            guard let c = Self.vcrCondition(k, in: VcrCondition.decks) else {
                throw CLIError(message: "No deck \"\(k)\". Decks: \(VcrCondition.decks.map(\.name).joined(separator: ", ")).")
            }
            state.applyVcrCondition(c, keys: VcrCondition.deckKeys)
        }
        try setGlitchValues(d["values"], groups: [.tape, .deck], panel: "VCR", state)
        state.vcrEnabled = (d["enabled"] as? Bool) ?? true
    }

    private mutating func setGlitchValues(_ raw: Any?, groups: Set<GlitchParam.Group>, panel: String,
                                          _ state: AppState) throws {
        guard let raw else { return }
        guard let values = raw as? [String: Any] else { throw CLIError(message: "\(panel) \"values\" is an object of control: value.") }
        let allowed = GlitchParam.all.filter { groups.contains($0.group) && $0.id != GlitchParam.vcrID }
        for (key, value) in values {
            guard let p = allowed.first(where: { $0.id == key }) else {
                let other = GlitchParam.byID[key].map { $0.group == .reception ? "glitch" : "vcr" }
                throw CLIError(message: other.map { "\"\(key)\" belongs to \"\($0)\", not \(panel)." }
                    ?? "No \(panel) control \"\(key)\". Controls: \(allowed.map(\.id).joined(separator: ", ")).")
            }
            let v: Double
            switch p.kind {
            case .slider(let lo, let hi, _, _): v = try clamped(value, lo, hi, key)
            case .toggle:
                guard let b = Self.bool(value) else { throw CLIError(message: "\(key) is on/off.") }
                v = b ? 1 : 0
            case .seed:
                guard let n = Self.number(value), n >= 0 else { throw CLIError(message: "\(key) is a whole number (which cassette).") }
                v = n.rounded()
            case .choice(let options):
                v = try Self.choiceIndex(value, options, key)
            }
            state.setGlitchValue(key, v)
        }
    }

    // MARK: CRT shader

    private mutating func applyCrt(_ v: Any, _ state: AppState) throws {
        var dict: [String: Any] = [:]
        if let s = v as? String {
            if Self.isOff(s) { state.shaderEnabled = false; return }
            if Self.isOn(s) { state.shaderEnabled = true; return }
            dict["preset"] = s
        } else if let d = v as? [String: Any] {
            dict = d
        } else {
            throw CLIError(message: "\"crt\" takes \"on\", \"off\", a preset id, or {preset, params, enabled}.")
        }
        if let id = dict["preset"] as? String {
            guard let preset = Presets.all.first(where: { $0.id == id.lowercased() || $0.displayName.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw CLIError(message: "No CRT preset \"\(id)\". Presets: \(Presets.all.map(\.id).joined(separator: ", ")).")
            }
            state.selectedPreset = preset
        }
        try setCrtParams(dict["params"], state)
        state.shaderEnabled = (dict["enabled"] as? Bool) ?? true
    }

    private mutating func setCrtParams(_ raw: Any?, _ state: AppState) throws {
        guard let raw else { return }
        guard let params = raw as? [String: Any] else { throw CLIError(message: "CRT \"params\" is an object of parameter: value.") }
        if !params.isEmpty {
            guard state.chain != nil else { throw CLIError(message: "The CRT shader failed to compile: \(state.chainError ?? "unknown error")", code: 1) }
            let byName = Dictionary(state.paramDescriptors.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            for (key, raw) in params {
                guard let p = byName[key] else {
                    throw CLIError(message: "CRT preset \(state.selectedPreset.id) has no parameter \"\(key)\". Run `NTSCRT describe crt --crt \(state.selectedPreset.id)` for its list.")
                }
                let value: Double
                if Self.isBoolean(raw) || raw is String && Self.bool(raw) != nil && Double(raw as! String) == nil {
                    value = Self.bool(raw)! ? 1 : 0
                } else {
                    value = try clamped(raw, Double(p.minimum), Double(p.maximum), "crt \(key)")
                }
                state.setParam(key, Float(value))
            }
        }
    }

    // MARK: keyframes (animation)

    static let keyStages = ["glitch", "vcr", "digital", "ntsc", "crt"]

    static func easing(_ name: String) -> KeyEasing? {
        let squashed = name.lowercased().filter(\.isLetter)
        return KeyEasing.allCases.first { $0.rawValue.lowercased().filter(\.isLetter) == squashed }
    }

    /// `"keyframes": [{"time": 0, "glitch": {"values": {…}}}, {"time": 2.5,
    /// "easing": "ease-in-out", "vcr": {"tape": "Chewed"}}, …]`. Each key is
    /// the look above it with these values changed; between keys values
    /// blend (whole-number controls step), as the app's timeline does. They
    /// replace any keyframes the look brought. A key at 0 holding the look
    /// itself is added when there isn't one.
    private mutating func applyKeyframes(_ v: Any, explicitDuration: Bool, _ state: AppState) throws {
        guard let list = v as? [[String: Any]] else {
            throw CLIError(message: "\"keyframes\" is a list of {time, easing, glitch, vcr, digital, ntsc, crt}.")
        }
        // Capture with the timeline off, so no edit lands in an old key.
        state.timelineEnabled = false
        state.timelineKeys = []
        if list.isEmpty { return }

        var timed: [(time: Double, key: [String: Any])] = []
        for key in list {
            guard let time = Self.number(key["time"]), time >= 0 else {
                throw CLIError(message: "Each keyframe needs a \"time\" in seconds (0 or more).")
            }
            let extra = Set(key.keys).subtracting(["time", "easing"] + Self.keyStages)
            if !extra.isEmpty {
                throw CLIError(message: "A keyframe can change \(Self.keyStages.joined(separator: ", ")) (not \(extra.sorted().joined(separator: ", "))): crop, downscale and the CRT preset hold for the whole video.")
            }
            timed.append((time, key))
        }
        timed.sort { $0.time < $1.time }

        // Times are seconds; the timeline stores them as 0…1 of its length.
        let last = timed.last!.time
        var duration = state.effectiveTimelineDuration
        if state.videoSource == nil, !explicitDuration, last > duration {
            state.timelineDuration = last
            duration = last
        }
        if last > duration + 1e-6 {
            warnings.append("Keyframes after \(Self.fmt(duration)) s are past the end of the video; they land at the end.")
        }

        let baseParams = state.paramValues, baseNtsc = state.ntscValues
        let baseGlitch = state.glitchValues, baseDigital = state.digitalValues
        func restore() {
            state.setAllParams(baseParams)
            state.applyNtscValues(baseNtsc)
            for (k, v) in baseGlitch { state.setGlitchValue(k, v) }
            for (k, v) in baseDigital { state.setDigitalValue(k, v) }
        }
        func snapshot(_ t: Double, _ easing: KeyEasing) -> Keyframe {
            Keyframe(t: t, easing: easing, shaderParams: state.paramValues, ntscValues: state.ntscValues,
                     glitchValues: state.glitchValues, digitalValues: state.digitalValues)
        }

        var keys: [Keyframe] = []
        var touched = Set<String>()
        if timed[0].time > 1e-6 { keys.append(snapshot(0, .linear)) }
        for (time, key) in timed {
            restore()
            var easing = KeyEasing.linear
            if let e = key["easing"] as? String {
                guard let parsed = Self.easing(e) else {
                    throw CLIError(message: "Easing \"\(e)\": use linear, ease-in, ease-out, ease-in-out or hold.")
                }
                easing = parsed
            }
            for stage in Self.keyStages where key[stage] != nil {
                touched.insert(stage)
                guard let d = key[stage] as? [String: Any] else {
                    if stage == "vcr", let s = key[stage] as? String, Self.isOn(s) || Self.isOff(s) {
                        state.vcrEnabled = Self.isOn(s); continue
                    }
                    throw CLIError(message: "In a keyframe, \"\(stage)\" is an object, as in the look (e.g. {\"values\": {…}}).")
                }
                switch stage {
                case "glitch": try setGlitchValues(d["values"], groups: [.reception], panel: "Glitch", state)
                case "vcr":
                    if let t = d["tape"] as? String {
                        guard let c = Self.vcrCondition(t, in: VcrCondition.tapes) else { throw CLIError(message: "No tape \"\(t)\".") }
                        state.applyVcrCondition(c, keys: VcrCondition.tapeKeys)
                    }
                    if let k = d["deck"] as? String {
                        guard let c = Self.vcrCondition(k, in: VcrCondition.decks) else { throw CLIError(message: "No deck \"\(k)\".") }
                        state.applyVcrCondition(c, keys: VcrCondition.deckKeys)
                    }
                    try setGlitchValues(d["values"], groups: [.tape, .deck], panel: "VCR", state)
                    if let on = d["enabled"].flatMap(Self.bool) { state.vcrEnabled = on }
                case "digital": try setDigitalValues(d["values"], state)
                case "ntsc": try setNtscSettings(d["settings"], state)
                case "crt": try setCrtParams(d["params"], state)
                default: break
                }
            }
            keys.append(snapshot(duration > 0 ? min(1, time / duration) : 0, easing))
        }
        restore()

        // A stage a keyframe animates has to be running to show it.
        if touched.contains("glitch") { state.glitchEnabled = true }
        if touched.contains("digital"), !state.digitalEnabled { state.setDigitalEnabled(true) }
        if touched.contains("ntsc") { state.ntscEnabled = true }
        if touched.contains("crt") { state.shaderEnabled = true }
        state.timelineKeys = keys
        state.timelineEnabled = true
        state.scrubTimeline(to: 0)
    }

    // MARK: timeline (a still's video length)

    private mutating func applyTimeline(_ v: Any, _ state: AppState) throws {
        guard let d = v as? [String: Any] else { throw CLIError(message: "\"timeline\" takes {duration, fps}.") }
        if let s = Self.number(d["duration"]) { state.timelineDuration = min(600, max(0.1, s)) }
        if let f = Self.number(d["fps"]) { state.timelineFPS = Int(min(120, max(1, f.rounded()))) }
    }

    // MARK: value parsing

    nonisolated static func isOn(_ s: String) -> Bool { ["on", "true", "yes", "1"].contains(s.lowercased()) }
    nonisolated static func isOff(_ s: String) -> Bool { ["off", "false", "no", "0", "none"].contains(s.lowercased()) }

    /// JSON's true/false (a CFBoolean — `is Bool` also matches 0 and 1).
    nonisolated static func isBoolean(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    nonisolated static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return isBoolean(n) ? (n.boolValue ? 1 : 0) : n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    nonisolated static func bool(_ v: Any) -> Bool? {
        if let n = v as? NSNumber { return isBoolean(n) ? n.boolValue : n.doubleValue >= 0.5 }
        if let s = v as? String { return isOn(s) ? true : (isOff(s) ? false : nil) }
        return nil
    }

    static func choiceIndex(_ v: Any, _ options: [String], _ name: String) throws -> Double {
        if let s = v as? String, let i = options.firstIndex(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) {
            return Double(i)
        }
        if let n = number(v), n.rounded() == n, n >= 0, Int(n) < options.count { return n }
        throw CLIError(message: "\(name) is one of: \(options.joined(separator: ", ")) (or its number, 0–\(options.count - 1)).")
    }

    private mutating func clamped(_ v: Any, _ lo: Double, _ hi: Double, _ name: String) throws -> Double {
        guard let n = Self.number(v), n.isFinite else { throw CLIError(message: "\(name) takes a number from \(Self.fmt(lo)) to \(Self.fmt(hi)).") }
        let c = min(hi, max(lo, n))
        if c != n { warnings.append("\(name) \(Self.fmt(n)) is outside \(Self.fmt(lo))…\(Self.fmt(hi)); used \(Self.fmt(c)).") }
        return c
    }

    static func fmt(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e9 ? String(Int(d)) : String(format: "%g", d)
    }
}
