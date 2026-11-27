import Foundation
import CrtAppBridge
import CrtCore

/// `NTSCRT describe [stage…] [--crt <preset>|all]` and `NTSCRT looks`: the
/// controls and named starting points, as JSON, for scripts and AI tools.
@MainActor
enum DescribeCommand {
    static let stages = ["crop", "downscale", "digital", "ntsc", "glitch", "vcr", "crt", "output"]

    static func run(_ args: [String]) async -> Int32 {
        do {
            CLI.emitText(CLI.prettyJSON(try describe(args)))
            return 0
        } catch let e as CLIError {
            CLI.emitJSON(["ok": false, "error": e.message])
            return e.code
        } catch {
            CLI.emitJSON(["ok": false, "error": error.localizedDescription])
            return 1
        }
    }

    static func runLooks(_ args: [String]) async -> Int32 {
        CLI.emitText(CLI.prettyJSON(looks()))
        return 0
    }

    static func describe(_ args: [String]) throws -> [String: Any] {
        var wanted: [String] = []
        var crtPresets: [String]? = nil
        var i = 0
        while i < args.count {
            if args[i] == "--crt" {
                i += 1
                guard i < args.count else { throw CLIError(message: "--crt needs a preset id, or all.") }
                crtPresets = args[i] == "all" ? Presets.all.map(\.id) : args[i].split(separator: ",").map(String.init)
            } else if stages.contains(args[i]) {
                wanted.append(args[i])
            } else {
                throw CLIError(message: "describe takes stages (\(stages.joined(separator: ", "))) and --crt <preset|all>.")
            }
            i += 1
        }
        if wanted.isEmpty { wanted = stages }
        let state = try Session.makeState()

        var out: [String: Any] = [
            "about": "NTSCRT renders images and video through simulated analog video gear. The picture passes through the stages in `order`; each stage's controls are set with `NTSCRT render` flags or a --settings JSON object keyed by stage (see `settingsExample`). Values are what the setting stores: a slider described as percent stores 0–1 (or −1–1), shown in the app as 0–100%.",
            "order": ["source", "crop", "digital", "ntsc", "downscale", "vcr", "glitch", "crt"],
            "settingsExample": [
                "look": "90s VHS bootleg",
                "vcr": ["tape": "Moldy", "deck": "Dirty heads", "values": ["tape_speed": "EP", "tracking_offset": 0.3]],
                "glitch": ["values": ["vertical_hold": 0.2]],
                "crt": ["preset": "royale"],
            ] as [String: Any],
            "keyframes": [
                "about": "Animate a look: \"keyframes\" in the settings is a list of moments, each the look above it with some values changed. Between keys values blend (on/off, choices and the cassette step instead); before the first key and after the last they hold. Times are seconds into the clip, or into the video a still becomes (a still's video stretches to the last key unless timeline.duration is set). A key at 0 holding the plain look is added when there isn't one. Keys can change glitch values, vcr (tape, deck, values, enabled), digital values, ntsc settings and crt params — not crop, downscale or the CRT preset. They replace any keyframes the look had. For a seamless loop, set \"timeline\": {\"duration\": 2, \"loop\": true}: it adds a closing key that copies the first.",
                "easing": "per key, shaping the move to the next key: linear (default), ease-in, ease-out, ease-in-out, hold (jump at the next key)",
                "example": [
                    ["time": 0],
                    ["time": 2, "easing": "ease-in", "glitch": ["values": ["vertical_hold": 0.5]]],
                    ["time": 3],
                    ["time": 5, "vcr": ["tape": "Chewed"]],
                ] as [[String: Any]],
            ] as [String: Any],
        ]
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { out["version"] = v }
        var stageInfo: [String: Any] = [:]
        for s in wanted {
            switch s {
            case "crop": stageInfo[s] = crop
            case "downscale": stageInfo[s] = downscale
            case "digital": stageInfo[s] = digital
            case "ntsc": stageInfo[s] = ntsc(state)
            case "glitch": stageInfo[s] = glitch
            case "vcr": stageInfo[s] = vcr
            case "crt": stageInfo[s] = try crt(state, presets: crtPresets ?? [state.selectedPreset.id])
            case "output": stageInfo[s] = output
            default: break
            }
        }
        out["stages"] = stageInfo
        return out
    }

    // MARK: - stages

    static var crop: [String: Any] {
        ["panel": "Crop",
         "about": "Cut the source to an aspect ratio before anything else runs.",
         "flag": "--crop 9:16[@x,y][*zoom] | off",
         "settings": "\"crop\": \"9:16\" | \"off\" | {\"ratio\": \"9:16\", \"x\": 0.5, \"y\": 0.5, \"zoom\": 1}",
         "values": ["ratio": "w:h, e.g. 1:1, 4:3, 9:16, 16:9", "x": "0–1, where the cut sits across", "y": "0–1, where it sits down", "zoom": "1–\(LookSettings.fmt(SourceCrop.maxScale)), zoomed in"]]
    }

    static var downscale: [String: Any] {
        ["panel": "Downscale",
         "about": "The resolution the picture is carried at: everything after it — NTSC, VCR, Glitch, CRT — works on lines this wide. 320 is a 240-line TV picture; 640 a sharper one.",
         "flag": "--downscale <width>|off  --downscale-method chunky|smooth",
         "settings": "\"downscale\": 320 | \"off\" | {\"width\": 320, \"method\": \"chunky\"}",
         "widths": ["SNES/NES": 256, "VGA": 320, "Arcade": 384, "VGA²": 640],
         "methods": ["chunky": "nearest-neighbor: hard pixels", "smooth": "area average"]]
    }

    static var digital: [String: Any] {
        ["panel": "Digital video",
         "about": "A camera and a video codec ahead of the TV signal: real 8×8 DCT blocks, quantization, motion-compensated frames, lost data. Off by default. A format sets the controls and the Downscale width.",
         "flag": "--digital <format>|on|off  --digital-set key=value,…",
         "settings": "\"digital\": \"minidv\" | \"off\" | {\"format\": \"minidv\", \"values\": {…}}",
         "formats": DigitalFormat.all.map { ["id": $0.id, "name": $0.name, "width": $0.width, "about": $0.blurb] as [String: Any] },
         "controls": DigitalParam.all.map { p -> [String: Any] in
             var c: [String: Any] = ["id": p.id, "label": p.label, "group": p.group.rawValue,
                                     "default": p.defaultValue, "help": p.help]
             switch p.kind {
             case .slider(let lo, let hi, let percent, let unit):
                 c["kind"] = "slider"; c["min"] = lo; c["max"] = hi
                 if percent { c["display"] = "percent" }
                 if !unit.isEmpty { c["unit"] = unit }
                 if p.step != nil { c["step"] = p.step }
             case .choice(let options):
                 c["kind"] = "choice"; c["options"] = options
             }
             return c
         }]
    }

    static func ntsc(_ state: AppState) -> [String: Any] {
        func control(_ s: NtscSetting) -> [String: Any]? {
            if NtscSetting.retiredVHS.contains(s.name) { return nil }
            var c: [String: Any] = ["id": s.name, "label": s.label]
            if let d = s.description, !d.isEmpty { c["help"] = d }
            if let def = state.ntscDefaults[s.name] { c["default"] = def }
            switch s.kind {
            case .boolean: c["kind"] = "toggle"
            case .percentage: c["kind"] = "slider"; c["min"] = 0; c["max"] = 1; c["display"] = "percent"
            case .float(let lo, let hi, _): c["kind"] = "slider"; c["min"] = lo; c["max"] = hi
            case .int(let lo, let hi): c["kind"] = "integer"; c["min"] = lo; c["max"] = hi
            case .enumeration(let options):
                c["kind"] = "choice"; c["options"] = options.map(\.label)
                // By name: the options are listed in the panel's order, not
                // ntsc-rs's numbering.
                if let def = (state.ntscDefaults[s.name] as? NSNumber)?.intValue,
                   let o = options.first(where: { $0.index == def }) { c["default"] = o.label }
            case .group(let kids):
                c["kind"] = "group"
                c["about"] = "A switch for the settings under it."
                c["children"] = kids.compactMap(control)
            case .section(let kids):
                c["kind"] = "section"
                c["children"] = kids.compactMap(control)
                c.removeValue(forKey: "default")
            }
            return c
        }
        var out: [String: Any] = [
            "panel": "NTSC (TV)",
            "about": "ntsc-rs's model of a composite NTSC signal: the picture encoded as luma and a color subcarrier, filtered, noised and decoded again — smear, ringing, color bleed and noise. On by default with the app's house settings. Its old VHS emulation (head switching, tracking noise, tape settings) is retired and hidden: use the VCR stage for tape.",
            "flag": "--ntsc on|off  --ntsc-set key=value,…",
            "settings": "\"ntsc\": \"off\" | {\"enabled\": true, \"settings\": {…}}",
            "controls": state.ntscDescriptors.compactMap(control),
        ]
        if !state.ntscAvailable { out["available"] = false }
        return out
    }

    static func glitchControl(_ p: GlitchParam) -> [String: Any] {
        var c: [String: Any] = ["id": p.id, "label": p.label, "default": p.defaultValue, "help": p.help]
        if p.group != .reception { c["group"] = p.group.rawValue }
        if let s = p.section { c["section"] = s }
        switch p.kind {
        case .slider(let lo, let hi, let percent, let unit):
            c["kind"] = "slider"; c["min"] = lo; c["max"] = hi
            if percent { c["display"] = "percent" }
            if !unit.isEmpty { c["unit"] = unit }
        case .toggle: c["kind"] = "toggle"
        case .seed:
            c["kind"] = "seed"
            c["note"] = "A whole number that picks which cassette (1, 2, 3…), not an amount. Only matters when the tape has flaws."
        case .choice(let options):
            c["kind"] = "choice"; c["options"] = options
            c["note"] = "Takes an option's name or its number (0 = first)."
        }
        switch p.id {
        case "tracking_offset":
            c["note"] = "Signed: ±1 is a whole track either way. Runs on a curve, so the picture holds over most of the travel and breaks up near the ends (|value| ≳ 0.6)."
        case "back_tension":
            c["note"] = "Signed: positive is tighter than the recording deck (skew, the top of the picture hooks sideways), negative is slacker (the top of the picture waves from side to side and gets noisy). 0 matches it. Up to ±0.5 is a deck out of adjustment; beyond, the effect grows four times as fast (a stretched tape: strong hooking, noise bars on LP and EP)."
        case "search_speed":
            c["note"] = "1 is normal play; 2–9 is fast-forward picture search."
        case "rf":
            c["note"] = "On: the picture reaches the TV as a game console's signal on channel 3 through the antenna socket — colored fringes on hard edges that crawl, fine detail softened, the tuner's noise; signal_strength and ghost_level act on that signal. Best on a low Downscale (256 or 320 wide). A typical console-on-RF look: rf on, signal_strength 0.82, ghost_level 0.14, ghost_delay 0.4, hum 0.04, rf_crawl 0.25, rf_color 1.75. Rough: signal_strength 0.72, ghost_level 0.24, ghost_delay 0.5, hum 0.1, rf_crawl 0.55, rf_color 2.65."
        case "rf_crawl":
            c["note"] = "Needs rf on. Dots crawling beside changes of color, harder outlines, somewhat stronger fringes, a crisper and grainier picture; little added color, and the picture's own color is not changed (that is rf_color). 0.25 typical, 0.55 rough, 1 extreme."
        case "rf_smear":
            c["note"] = "Needs rf on. The color trails to the right of what it colors and is thin inside left edges; brightness stays put. 0.25 slight, 0.5 typical RF, 1 heavy (about 4 pixels late at 256 wide)."
        case "rf_soft":
            c["note"] = "Needs rf on. Blurs the brightness's detail (small text merges); color and levels untouched. 0.2 typical RF."
        case "rf_offset":
            c["note"] = "Needs rf on. The set tuned off the channel: detail loses contrast with a halo round shapes, color weakens and gets noisy and unsteady, then drops to black and white from about 0.85. 0.3 is a set not quite on the channel."
        case "rf_color":
            c["note"] = "Needs rf on. The picture's own color: 0 black and white, 1 as sent, up to 4 (garish). 1.3 to 1.75 is how RF usually looked; fringes and noise are rf_crawl's."
        default: break
        }
        return c
    }

    static var glitch: [String: Any] {
        ["panel": "Glitch",
         "about": "The TV set and the broadcast reaching it: weak signal, hold controls, ghosts, hum. A simulation of the receiver's circuits; every knob is one a real set had. On by default with every knob healthy, which changes nothing.",
         "flag": "--glitch on|off  --glitch-set key=value,…",
         "settings": "\"glitch\": \"off\" | {\"values\": {\"signal_strength\": 0.4}}",
         "controls": GlitchParam.controls(in: .reception).map(glitchControl)]
    }

    static func condition(_ c: VcrCondition) -> [String: Any] {
        ["name": c.name, "about": c.help, "values": c.values]
    }

    static var vcr: [String: Any] {
        ["panel": "VCR",
         "about": "Plays the picture off a simulated VHS tape: recorded as FM on slanted tracks, read back by two spinning heads, through the tape's condition and the deck's. Off by default. History matters — clogs build up as it plays, the tracking servo hunts, creases sweep through over seconds — so look at more than the first frame. The Tape and Deck pickers set a whole condition at once; set `values` after them to adjust.",
         "flag": "--vcr on|off  --tape <name>  --deck <name>  --vcr-set key=value,…   (any of these but --vcr off switches it on)",
         "settings": "\"vcr\": \"on\" | \"off\" | {\"tape\": \"Moldy\", \"deck\": \"Dirty heads\", \"values\": {\"tape_speed\": \"LP\"}}",
         "tapes": VcrCondition.tapes.map(condition),
         "decks": VcrCondition.decks.map(condition),
         "cost": "Each Generation (copy) is a full extra playback: a Third copy takes about four times as long as an Original.",
         "controls": (GlitchParam.controls(in: .tape) + GlitchParam.controls(in: .deck)).map(glitchControl)]
    }

    static func crt(_ state: AppState, presets ids: [String]) throws -> [String: Any] {
        var presets: [[String: Any]] = []
        for id in ids {
            guard let preset = Presets.all.first(where: { $0.id == id }) else {
                throw CLIError(message: "No CRT preset \"\(id)\". Presets: \(Presets.all.map(\.id).joined(separator: ", ")).")
            }
            let url = state.presetsRoot.appendingPathComponent(preset.relativePath)
            guard let chain = try? LRShaderChain(presetPath: url.path, commandQueue: state.context.queue) else {
                throw CLIError(message: "CRT preset \(id) failed to compile.", code: 1)
            }
            var seen = Set<String>()
            let defaults = AppState.appShaderDefaults[id] ?? [:]
            let params: [[String: Any]] = chain.parameters().compactMap { p in
                guard seen.insert(p.name).inserted else { return nil }
                let pres = presentation(for: p)
                if case .header = pres.kind { return nil }
                var c: [String: Any] = ["id": p.name, "label": pres.title,
                                        "min": Double(p.minimum), "max": Double(p.maximum),
                                        "default": Double(defaults[p.name] ?? p.initial)]
                if p.step > 0 { c["step"] = Double(p.step) }
                switch pres.kind {
                case .toggle: c["kind"] = "toggle"
                case .picker(let values, let labels, _):
                    c["kind"] = "choice"
                    c["values"] = values.map(Double.init)
                    if let labels { c["options"] = labels }
                case .stepper: c["kind"] = "integer"
                default: c["kind"] = "slider"
                }
                if let cap = pres.caption { c["note"] = cap }
                return c
            }
            presets.append(["id": preset.id, "name": preset.displayName, "params": params])
        }
        return ["panel": "CRT",
                "about": "A CRT shader (libretro slang presets via librashader): scanlines, the shadow mask, glow, curvature. On by default with CRT Glow (Gaussian). Each preset has its own parameters; describe one with --crt <id>.",
                "flag": "--crt <preset>|on|off  --crt-set param=value,…",
                "settings": "\"crt\": \"royale\" | \"off\" | {\"preset\": \"royale\", \"params\": {…}}",
                "presetIDs": Presets.all.map { ["id": $0.id, "name": $0.displayName] },
                "default": "glow_gauss",
                "presets": presets]
    }

    static var output: [String: Any] {
        ["about": "What `render` writes, chosen by the -o extension or --format.",
         "formats": ["mp4": "H.264 (or --format hevc)", "mov": "ProRes 422 (--format prores-hq for HQ)",
                     "gif": "GIF at its own width (--gif-width, default 480) and frame rate (--gif-fps, default 12)",
                     "png": "one frame; --time 0,1.5,3 writes one per time"],
         "size": "--long-edge N (default 1920) at the source's aspect; --snap rounds to the scanline grid",
         "length": "a clip renders whole; a still becomes a video of --duration seconds (default 5) at --fps (default 30), or its look's timeline",
         "other": "--quality standard|high|very-high|maximum, --loops N, --save-look file.json, --dry-run"]
    }

    // MARK: - looks

    static func looks() -> [String: Any] {
        let builtIn = LookSettings.builtInLooks().map { look -> [String: Any] in
            var o: [String: Any] = ["name": look.name]
            if let data = FileManager.default.contents(atPath: look.url.path),
               let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let text = d["description"] as? String { o["description"] = text }
                o["stages"] = lookStages(d)
            }
            return o
        }
        return [
            "looks": builtIn,
            "about": "Whole looks: pass a name to --look (or \"look\" in --settings), then adjust any stage. Tapes and decks are the VCR's pickers; formats are Digital video's; presets are the CRT's.",
            "tapes": VcrCondition.tapes.map(condition),
            "decks": VcrCondition.decks.map(condition),
            "digitalFormats": DigitalFormat.all.map { ["id": $0.id, "name": $0.name, "about": $0.blurb] },
            "crtPresets": Presets.all.map { ["id": $0.id, "name": $0.displayName] },
        ]
    }

    /// A look file's stages in brief, read from the file itself.
    static func lookStages(_ d: [String: Any]) -> [String: Any] {
        func on(_ key: String, default def: Bool) -> Bool { (d[key] as? [String: Any])?["enabled"] as? Bool ?? def }
        var s: [String: Any] = [:]
        if let c = d["crop"] as? [String: Any], let r = c["ratio"] { s["crop"] = r }
        let dig = d["digital"] as? [String: Any]
        if on("digital", default: false) {
            let values = (dig?["values"] as? [String: Double]) ?? [:]
            let width = (d["downscale"] as? [String: Any])?["width"] as? Int ?? 0
            s["digital"] = DigitalFormat.matching(values: values, width: width)?.name ?? "custom"
        }
        s["ntsc"] = on("ntsc", default: true)
        if on("downscale", default: true), let w = (d["downscale"] as? [String: Any])?["width"] { s["downscale"] = w }
        let g = (d["glitch"] as? [String: Any])?["values"] as? [String: Double] ?? [:]
        let values = GlitchSettings.migrated(GlitchSettings.upgraded(g, lookVersion: d["version"] as? Int ?? 1))
        if (values[GlitchParam.vcrID] ?? 0) >= 0.5 {
            let full = GlitchParam.defaultValues.merging(values) { _, n in n }
            s["vcr"] = ["tape": VcrCondition.matching(VcrCondition.tapes, keys: VcrCondition.tapeKeys, in: full)?.name ?? "custom",
                        "deck": VcrCondition.matching(VcrCondition.decks, keys: VcrCondition.deckKeys, in: full)?.name ?? "custom"]
        }
        if on("glitch", default: true),
           GlitchParam.controls(in: .reception).contains(where: { abs((values[$0.id] ?? $0.defaultValue) - $0.defaultValue) > 1e-9 }) {
            s["glitch"] = true
        }
        let shader = d["shader"] as? [String: Any]
        s["crt"] = (shader?["enabled"] as? Bool ?? true) ? (shader?["preset"] as? String ?? "glow_gauss") : "off"
        if let keys = (d["timeline"] as? [String: Any])?["keys"] as? [Any], !keys.isEmpty { s["keyframes"] = keys.count }
        return s
    }
}
