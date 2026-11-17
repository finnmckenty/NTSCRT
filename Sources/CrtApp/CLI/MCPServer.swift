import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `NTSCRT mcp`: a Model Context Protocol server on stdin/stdout, so an AI
/// app (Claude Desktop, Claude Code, …) can make looks and render with
/// NTSCRT. Every tool runs this same executable's `render`/`describe`/
/// `looks` as a child process — a render that fails takes nothing down,
/// and the server itself never touches the GPU.
@MainActor
enum MCPServer {
    static let serverVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static func run(_ args: [String]) async -> Int32 {
        let lines = AsyncStream<String> { continuation in
            Thread.detachNewThread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
        }
        CLI.log("NTSCRT MCP server \(serverVersion) ready on stdio.")
        for await line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            Task { await handle(message) }
        }
        Jobs.shared.cancelAll()
        return 0
    }

    // MARK: - JSON-RPC

    static func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        CLI.resultOut.write(data + Data("\n".utf8))
    }

    static func handle(_ message: [String: Any]) async {
        let id = message["id"]
        guard let method = message["method"] as? String else { return }  // a response: none expected
        let params = message["params"] as? [String: Any] ?? [:]
        func reply(_ result: [String: Any]) {
            if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) }
        }
        func fail(_ code: Int, _ text: String) {
            if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]) }
        }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? supportedProtocols[0]
            reply(["protocolVersion": supportedProtocols.contains(asked) ? asked : supportedProtocols[0],
                   "capabilities": ["tools": ["listChanged": false]],
                   "serverInfo": ["name": "ntscrt", "title": "NTSCRT", "version": serverVersion],
                   "instructions": instructions])
        case "ping":
            reply([:])
        case "tools/list":
            reply(["tools": Tools.list])
        case "tools/call":
            guard let name = params["name"] as? String else { return fail(-32602, "tools/call needs a name") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            reply(await Tools.call(name, arguments))
        case let m where m.hasPrefix("notifications/"):
            break
        default:
            fail(-32601, "Method not found: \(method)")
        }
    }

    /// The craft notes (Finn's, from making looks), by topic: what the
    /// control descriptions can't say. Read through ntscrt_guide, so they
    /// cost a chat nothing until a look is being made.
    static let guide: [(id: String, title: String, text: String)] = [
        ("stages", "Which stage for which words", """
        - VHS, tape, VCR, rental, bootleg, dub, tracking, worn or moldy tape, head clog: the vcr stage. Pick a tape and a deck condition first (they're balanced combinations), then adjust its values. Generation makes copies of copies; tape_speed EP is lower quality. Don't use the ntsc stage's old VHS settings (they're retired).
        - Softness, color bleeding sideways, composite noise, dot crawl: the ntsc stage (on by default with a mild house setting).
        - Old TV, CRT, scanlines, arcade, retro game: the crt stage. glow_gauss is the default; royale shows a detailed shadow mask; hyllian and easymode are sharper, for games. "crt": "off" for footage that should look like a digitized tape rather than a screen.
        - Broadcast, antenna, bad reception, snow, rolling, picture slipping sideways, ghosting, hum bars: the glitch stage (signal_strength, vertical_hold, horizontal_hold, ghost_level, hum).
        - Webcam, video call, camcorder, MiniDV, skate video, early internet video, streaming, CD-ROM, compression, blocks, datamosh: the digital stage; start from a format or a look.
        """),
        ("digital", "Digital video", """
        - Glitchy digital video: block video at fairly low quality (roughly 0.3–0.6), and above all a long keyframe interval (3–6 s) with moderate data_loss, so lost data smears and hangs until the next keyframe (see the "glitchy block video" look). Glitchy streaming video is different: a long keyframe interval or a fixed bitrate adds a lot of noise, which most users won't want, so leave both off unless they ask to go really overboard ("glitchy streaming video" vs "glitchy streaming video with noise"). These errors live in motion: on a still image they barely show, since a lost block repeats an identical frame.
        - Don't stack Digital video with the analog stages (ntsc, vcr, glitch) unless the user asks: that would be streaming video recorded onto a VHS tape, an unlikely thing. With Digital video, switch ntsc off ("ntsc": "off") and leave vcr and glitch off. Digital video with the CRT makes sense for a vintage computer monitor, when the user says so; otherwise Digital video alone is closest to what people picture.
        """),
        ("resolution", "Resolution, scanlines, sampling, pixel art and close-ups", """
        - Sampling (downscale "method": "chunky" or "smooth") matters a lot. Chunky picks single pixels, so the NTSC stage's fine noise survives as much stronger, sparkly noise, and the CRT draws hard, crisp pixels; smooth averages, so the noise calms down and edges soften. Neither is better: choose by what the user wants (grit and crispness, or a cleaner, softer picture).
        - Pixel art (game screenshots, sprites, low-resolution graphics with hard pixel edges): the user almost always wants each art pixel to stay crisp under sharp, even scanlines. Any mismatch between the art's own pixel grid and the lines the CRT draws, or smooth sampling, blurs edges into sub-pixel mush. So: check the source size (the result's look.source) and the art's pixel size. If the art is at its native resolution (e.g. 256 or 320 wide), switch downscale off or set it to exactly that width. If it's an upscaled screenshot, set the width to its native resolution (source width ÷ the size of one art pixel, e.g. 1024 ÷ 4 = 256), or a whole-number fraction of it. Use chunky, never smooth, and set snap so every line gets the same number of output rows. Usually leave the ntsc stage off or very light for pixel art unless the user wants composite artifacts.
        - Resolution: downscale width. 320 is a typical TV picture; lower is chunkier, 640 is sharp. Portrait video: crop "9:16" and a lower width.
        - A close-up of the CRT itself (huge scanlines, the phosphor mask's slots or dots visible, as if a camera were pressed to the screen): downscale hard (128–160, 256 at most), then zoom 8–12 on a PNG (zoom and zoom_at on ntscrt_preview and ntscrt_render); choose zoom_at over the interesting part of the picture. This is how it's done in the app too: zoom the preview way in and Export viewport. A mask-heavy CRT preset (royale, aperture) shows the mask most.
        - Prominent scanlines come from a LOW downscale width, not a high one. The CRT draws one scanline per line of the picture it gets, so fewer lines means bigger, more visible scanlines: 128–192 for bold, chunky scanlines (several bundled looks use 128 or 160), 256–320 for normal ones, 640 for fine, faint ones. Users often assume higher resolution is better; when they ask for visible scanlines or a chunky retro look, lower the width and say why.
        """),
        ("strength", "How strong", """
        - Start moderate and go further only when asked. "A bit of", "subtle", "slightly": values around 0.1–0.3. "Worn", "old": 0.4–0.6. "Destroyed", "barely watchable": 0.8 and up.
        - Damage compounds: several high values together quickly make the picture unrecognizable. Raise one or two at a time and preview.
        - The VCR switched on with a Brand new tape and Clean heads already looks like VHS; damage is optional.
        """),
        ("timing", "Changes over time and glitch timing", """
        Over time: anything that happens partway through (the picture starts to roll, the signal fades, a tape gets chewed) is keyframes. Add "keyframes" to the settings and preview before, during and after each change.
        Glitchy, edgy styles (glitch, glitchy, chaotic, broken, corrupted, aggressive, "freak out", and the like) live on dynamic timing: short bursts of extreme values with longer stretches of relative calm between them. Even, evenly spaced sweeps read as a filter, not a glitch. Build each burst from 3–5 keyframes about 0.08–0.2 s apart (calm → spike → different spike → back to calm), leave 0.5–1.5 s of a steady, mildly damaged picture between bursts, and vary which controls spike and how far (vertical_hold and horizontal_hold near ±1, signal_strength down to 0.3, search_speed up to 9, ghost_level, tracking_offset, crt or ntsc values). The bundled glitch looks (Glitch pop, Two blips loop, 2 second glitch, Vertical Freak Out) are built this way; preview inside a burst as well as between them. Gentle styles (dreamy, nostalgic, home video) want few, slow changes or none.
        """),
        ("stills", "Still images: animating, loops and variations", """
        Still images: one of NTSCRT's distinctive uses is turning a still into an animated asset. Even without keyframes the noise, the tape and the CRT make it move; keyframes add events. So when the source is a still and the user hasn't said, ask in one question: keep it a still image (render a PNG), or animate it? If animated: how long (2–5 s is typical), GIF or video, and should it loop seamlessly?
        - It works especially well on high-contrast images: line drawings, engravings, lettering and graffiti, logos, silhouettes on dark or flat backgrounds. Their hard edges show the bleed, ringing, tearing and scanlines clearly. On these, try a low downscale width (128–256), strong color, and the CRT on.
        - Loops: set "timeline": {"duration": <seconds>, "loop": true}. It adds a closing keyframe that copies the first, so the keyed values meet at the seam. Keep bursts off the seam unless the user wants one there. Some VCR conditions build up over time and never come back to where they started (tape_creases, dirt_buildup, tape_edge_damage, tape_sticky), so keep them low or off in loops, and back_tension and transport_flutter mild. Check the seam: preview at 0 and at the last frame (duration minus 1/fps); apart from the noise they should match.
        - Many variations of one still ("give me 12 versions", "a bunch of options"): do NOT preview and render them one by one. Build ONE long timeline (10–20 s, or about 1 s per variation wanted) whose keyframes push many controls far and unevenly (crt params, ntsc settings, glitch and vcr values, digital values), then make a single ntscrt_render call with format "png" and times spread across it (one per variation, plus a few spares). Unexpected combinations are the point. Preview a handful at a small size first to check the range isn't all destroyed or all tame, tell the user where the files are and which time each came from, and save the look so any of them can be found again on the app's timeline. It's one render instead of dozens of calls, and it finds looks nobody would set by hand.
        """),
    ]

    static let instructions = """
    NTSCRT renders images and video through simulated analog video gear: a camera and codec (Digital video), an NTSC composite signal, a VHS tape in a VCR, a TV receiver (Glitch), and a CRT screen. Each is simulated physically, so effects combine the way real ones did.

    How to work:
    1. Before choosing any settings, call ntscrt_guide once in the conversation and follow it. It holds the non-obvious rules: which stage fits which words, how strong to go, why bold scanlines need a LOW resolution, keeping pixel art crisp, glitch timing, and animating stills. Skipping it gives generic, usually wrong looks.
    2. Start from ntscrt_list_looks: each built-in look has a description; start from one when it's close. Read ntscrt_describe for the stages you'll change.
    3. Preview with ntscrt_preview and look at the images before rendering. The VCR and Glitch stages change over time, so preview several times (e.g. 0.5, 2 and 4 s).
    4. Adjust and preview again until it matches, then ntscrt_render. If it isn't finished when the call returns, poll ntscrt_render_status. Tell the user where the file is.
    5. Offer ntscrt_save_look, with a one-line description, so the user can open the look in the NTSCRT app.

    Ask before starting only about what the user left open: if the source is a still image and they haven't said whether they want a still or an animation, ask in one question (and, if animated, how long, GIF or video, and whether it should loop). If they already named a format and length ("a 4 second MP4"), don't ask: make a video that doesn't loop unless they said loop or asked for a GIF.

    Settings are one JSON object keyed by stage, applied after the "look": {"look": "90s VHS bootleg", "vcr": {"tape": "Moldy", "deck": "Dirty heads", "values": {"tape_speed": "EP"}}, "glitch": {"values": {"vertical_hold": 0.2}}, "crt": {"preset": "royale"}}. Values are numbers, true/false, or a choice's name. Sources and outputs are absolute file paths on the user's computer; if the user attaches a file instead of giving a path, ask for the path (on a Mac: select it in Finder and press Option-Command-C).
    """
}

// MARK: - tools

@MainActor
enum Tools {
    static let settingsSchema: [String: Any] = [
        "type": "object",
        "description": "The look, keyed by stage, applied in this order: look (a built-in look name or a .json look path), crop, downscale, digital, ntsc, glitch, vcr, crt, timeline ({duration, fps} for a still), keyframes. Each stage takes \"on\"/\"off\" or an object — e.g. {\"vcr\": {\"tape\": \"Moldy\", \"deck\": \"Dirty heads\", \"values\": {\"tape_speed\": \"EP\"}}, \"crt\": {\"preset\": \"royale\", \"params\": {}}, \"digital\": {\"format\": \"minidv\"}, \"downscale\": {\"width\": 320, \"method\": \"chunky\"}, \"crop\": \"9:16\"}. To animate, add \"keyframes\": [{\"time\": 0}, {\"time\": 2, \"easing\": \"ease-in\", \"glitch\": {\"values\": {\"vertical_hold\": 0.5}}}, {\"time\": 4, \"vcr\": {\"tape\": \"Chewed\"}}] — each key is the look with those values changed at that many seconds, blending between keys (glitch, vcr, digital, ntsc and crt values only). See ntscrt_describe for every control and the keyframe rules.",
        "additionalProperties": true,
    ]

    static let list: [[String: Any]] = [
        [
            "name": "ntscrt_list_looks",
            "title": "List looks",
            "description": "Named starting points: NTSCRT's built-in looks (each with a description of what it looks like and the stages it uses), the VCR's Tape and Deck conditions, Digital video formats and CRT presets.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "ntscrt_guide",
            "title": "How to make looks",
            "description": "Read this first, once per conversation, before choosing any settings: the craft rules for NTSCRT — which stage fits which words, how strong to go, resolution and scanlines (bold scanlines need a LOW resolution), sampling and pixel art, CRT close-ups, Digital video, glitch timing, and animating still images (loops, variations). Optional topics narrow it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "topics": ["type": "array", "items": ["type": "string", "enum": MCPServer.guide.map { $0.id }],
                               "description": "Sections to read (default: all)."],
                ] as [String: Any],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "ntscrt_describe",
            "title": "Describe controls",
            "description": "Every control of the stages asked for: id, kind (slider, toggle, choice, seed, integer), range, default, and what it does. Stages: crop, downscale, digital, ntsc, glitch, vcr, crt, output. CRT parameters depend on the preset; pass crt_preset for one other than the default (glow_gauss).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "stages": ["type": "array", "items": ["type": "string", "enum": DescribeCommand.stages],
                               "description": "Stages to describe (default: all)."],
                    "crt_preset": ["type": "string", "description": "A CRT preset id, or \"all\"."],
                ] as [String: Any],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "ntscrt_preview",
            "title": "Preview a look",
            "description": "Render a few frames of the source with the settings and return them as images, to check a look before rendering the whole video. Times are seconds into the clip (or into the video a still becomes); the VCR and Glitch stages change over time, so ask for several.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "source": ["type": "string", "description": "Absolute path of an image (PNG, JPEG, HEIC) or video (MP4, MOV)."],
                    "settings": settingsSchema,
                    "times": ["type": "array", "items": ["type": "number"], "description": "Seconds (default [0.5, 2, 4])."],
                    "long_edge": ["type": "integer", "description": "Preview size in pixels (default 640)."],
                    "snap": ["type": "boolean", "description": "Round the output size to a whole number of pixels per scanline, as the app's \"Snap size to scanline grid\": even, crisp scanlines. Use for pixel art."],
                    "zoom": ["type": "number", "description": "Magnify like the app's preview zoomed in (1–12): a close-up of the CRT's scanlines and phosphor mask. Pair with a low downscale width."],
                    "zoom_at": ["type": "array", "items": ["type": "number"], "description": "Where to zoom, [x, y] from 0 to 1 (default the center)."],
                ] as [String: Any],
                "required": ["source"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "ntscrt_render",
            "title": "Render a video",
            "description": "Render the source with the settings to a file: a clip in full, or a still as a video of `duration` seconds. Waits up to wait_seconds (default 45) and returns the result, or a job id to poll with ntscrt_render_status. Renders run one at a time.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "source": ["type": "string", "description": "Absolute path of an image or video."],
                    "settings": settingsSchema,
                    "output": ["type": "string", "description": "Where to write it (.mp4, .mov, .gif or .png). Default: ~/Movies/NTSCRT/<source name> <time>.mp4."],
                    "format": ["type": "string", "enum": ["h264", "hevc", "prores", "prores-hq", "gif", "png"], "description": "Default: from the output's extension, else h264. png writes full-size stills at `times`."],
                    "zoom": ["type": "number", "description": "For png: magnify like the app's preview zoomed in (1–12), for CRT close-ups."],
                    "zoom_at": ["type": "array", "items": ["type": "number"], "description": "For png: where to zoom, [x, y] from 0 to 1."],
                    "times": ["type": "array", "items": ["type": "number"], "description": "For png: seconds to take a frame at, one file each (named <output> <time>s.png). Use with a varied keyframed timeline to make many alternate stills."],
                    "duration": ["type": "number", "description": "A still's video length in seconds (default 5, or the look's)."],
                    "fps": ["type": "integer", "description": "A still's frame rate (default 30)."],
                    "long_edge": ["type": "integer", "description": "Output long edge in pixels (default 1920)."],
                    "snap": ["type": "boolean", "description": "Round the output size to a whole number of pixels per scanline, as the app's \"Snap size to scanline grid\": even, crisp scanlines. Use for pixel art."],
                    "quality": ["type": "string", "enum": ["standard", "high", "very-high", "maximum"]],
                    "loops": ["type": "integer", "description": "Repeat the content this many times in the file."],
                    "gif_width": ["type": "integer"], "gif_fps": ["type": "integer"],
                    "wait_seconds": ["type": "number", "description": "How long to wait for it to finish (0–100, default 45)."],
                ] as [String: Any],
                "required": ["source"],
            ],
        ],
        [
            "name": "ntscrt_render_status",
            "title": "Render status",
            "description": "A render's progress, time left, and — when done — its output file. Waits up to wait_seconds (default 30) for it to finish.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "job_id": ["type": "string"],
                    "wait_seconds": ["type": "number"],
                ] as [String: Any],
                "required": ["job_id"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "ntscrt_save_look",
            "title": "Save a look",
            "description": "Save the settings as an NTSCRT look file, which the app opens with Preset > Load Preset….",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "settings": settingsSchema,
                    "path": ["type": "string", "description": "Where to save it (.json). Default: ~/Movies/NTSCRT/Looks/<name>.json."],
                    "name": ["type": "string", "description": "The look's name, for the default path."],
                    "description": ["type": "string", "description": "One line on what it looks like, kept in the file (shown as the look's tooltip in the app)."],
                ] as [String: Any],
                "required": ["settings"],
            ],
        ],
    ]

    static func call(_ name: String, _ a: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "ntscrt_list_looks":
                return text(try await Child.run(["looks"]).stdout)
            case "ntscrt_guide":
                let wanted = (a["topics"] as? [String]).map(Set.init)
                let text = MCPServer.guide.filter { wanted?.contains($0.id) ?? true }
                    .map { "## \($0.title)\n\n\($0.text)" }.joined(separator: "\n\n")
                return Tools.text(text.isEmpty ? "No such topic. Topics: \(MCPServer.guide.map(\.id).joined(separator: ", "))." : text)
            case "ntscrt_describe":
                var args = ["describe"] + ((a["stages"] as? [String]) ?? [])
                if let p = a["crt_preset"] as? String { args += ["--crt", p] }
                let r = try await Child.run(args)
                return r.status == 0 ? text(r.stdout) : error(r.stdout)
            case "ntscrt_preview":
                return try await preview(a)
            case "ntscrt_render":
                return try await render(a)
            case "ntscrt_render_status":
                guard let id = a["job_id"] as? String, let job = Jobs.shared.jobs[id] else {
                    return error("No render with that job_id.")
                }
                await job.wait(seconds: wait(a, 30))
                return json(job.status)
            case "ntscrt_save_look":
                return try await saveLook(a)
            default:
                return error("Unknown tool \(name).")
            }
        } catch {
            return self.error(error.localizedDescription)
        }
    }

    // MARK: tool bodies

    static func preview(_ a: [String: Any]) async throws -> [String: Any] {
        let source = try path(a["source"], "source")
        let times = (a["times"] as? [Any])?.compactMap { LookSettings.number($0) } ?? [0.5, 2, 4]
        let longEdge = Int(LookSettings.number(a["long_edge"]) ?? 640)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ntscrt-mcp/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var args = ["render", source, "-o", dir.appendingPathComponent("preview.png").path,
                    "--time", times.map { String($0) }.joined(separator: ","),
                    "--long-edge", String(min(1600, max(128, longEdge)))]
        args += zoomArgs(a)
        args += try settingsArgs(a["settings"], in: dir)
        let r = try await Child.run(args)
        guard r.status == 0, var result = r.result, let outputs = result["outputs"] as? [[String: Any]] else {
            return error(r.errorText)
        }
        var content: [[String: Any]] = []
        for o in outputs {
            guard let p = o["path"] as? String, let jpeg = jpegData(p) else { continue }
            content.append(["type": "text", "text": "t = \(o["time"] ?? 0) s"])
            content.append(["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"])
        }
        result.removeValue(forKey: "outputs")
        result.removeValue(forKey: "plan")
        result.removeValue(forKey: "elapsed")
        content.insert(["type": "text", "text": CLI.prettyJSON(result)], at: 0)
        return ["content": content]
    }

    static func render(_ a: [String: Any]) async throws -> [String: Any] {
        let source = try path(a["source"], "source")
        let format = a["format"] as? String
        var output: String
        if let o = a["output"] as? String {
            output = (o as NSString).expandingTildeInPath
        } else {
            let ext = format == "gif" ? "gif" : format == "png" ? "png" : (format?.hasPrefix("prores") == true ? "mov" : "mp4")
            let stamp = { () -> String in let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f.string(from: Date()) }()
            let stem = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
            output = moviesFolder.appendingPathComponent("\(stem) \(stamp).\(ext)").path
        }
        guard output.hasPrefix("/") else { return error("output must be an absolute path.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ntscrt-mcp/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var args = ["render", source, "-o", output]
        if let format { args += ["--format", format] }
        for (key, flag) in [("long_edge", "--long-edge"), ("fps", "--fps"), ("loops", "--loops"),
                            ("gif_width", "--gif-width"), ("gif_fps", "--gif-fps")] {
            if let n = LookSettings.number(a[key]) { args += [flag, String(Int(n))] }
        }
        if let d = LookSettings.number(a["duration"]) { args += ["--duration", String(d)] }
        if let q = a["quality"] as? String { args += ["--quality", q] }
        if let times = (a["times"] as? [Any])?.compactMap({ LookSettings.number($0) }), !times.isEmpty {
            args += ["--time", times.map { String($0) }.joined(separator: ",")]
        }
        args += zoomArgs(a)
        args += try settingsArgs(a["settings"], in: dir)

        // Check it first (bad settings, the size and length) without the wait.
        let dry = try await Child.run(args + ["--dry-run"])
        guard dry.status == 0 else { try? FileManager.default.removeItem(at: dir); return error(dry.errorText) }
        let job = Jobs.shared.start(args: args, output: output, plan: dry.result?["plan"], cleanup: dir)
        await job.wait(seconds: wait(a, 45))
        return json(job.status)
    }

    static func saveLook(_ a: [String: Any]) async throws -> [String: Any] {
        var target: String
        if let p = a["path"] as? String {
            target = (p as NSString).expandingTildeInPath
        } else {
            let name = (a["name"] as? String)?.replacingOccurrences(of: "/", with: "-") ?? "NTSCRT look"
            target = moviesFolder.appendingPathComponent("Looks/\(name).json").path
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: target).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ntscrt-mcp/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var settings = (a["settings"] as? [String: Any]) ?? [:]
        if let d = a["description"] as? String { settings["description"] = d }
        let r = try await Child.run(["render", "--save-look", target] + (try settingsArgs(settings.isEmpty ? nil : settings, in: dir)))
        return r.status == 0 ? json(r.result ?? [:]) : error(r.errorText)
    }

    // MARK: helpers

    static var moviesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/NTSCRT")
    }

    static func path(_ v: Any?, _ name: String) throws -> String {
        guard let s = v as? String, !s.isEmpty else { throw CLIError(message: "\(name) is required.") }
        let p = (s as NSString).expandingTildeInPath
        guard p.hasPrefix("/") else { throw CLIError(message: "\(name) must be an absolute path (got \(s)).") }
        return p
    }

    /// The settings as a file for `--settings @file` (arguments have a
    /// length limit; a look's keyframes don't).
    static func settingsArgs(_ v: Any?, in dir: URL) throws -> [String] {
        guard let v else { return [] }
        let settings: [String: Any]
        if let d = v as? [String: Any] {
            settings = d
        } else if let s = v as? String, let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
            settings = d
        } else {
            throw CLIError(message: "settings must be a JSON object keyed by stage.")
        }
        if settings.isEmpty { return [] }
        let file = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: settings).write(to: file)
        return ["--settings", "@" + file.path]
    }

    static func zoomArgs(_ a: [String: Any]) -> [String] {
        var out: [String] = []
        if let snap = a["snap"].flatMap(LookSettings.bool), snap { out.append("--snap") }
        if let z = LookSettings.number(a["zoom"]), z > 1 { out += ["--zoom", String(z)] }
        if let xy = (a["zoom_at"] as? [Any])?.compactMap({ LookSettings.number($0) }), xy.count == 2 {
            out += ["--zoom-at", "\(xy[0]),\(xy[1])"]
        }
        return out
    }

    static func wait(_ a: [String: Any], _ def: Double) -> Double {
        min(100, max(0, LookSettings.number(a["wait_seconds"]) ?? def))
    }

    static func jpegData(_ path: String) -> Data? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func text(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]]] }
    static func json(_ o: [String: Any]) -> [String: Any] {
        ["content": [["type": "text", "text": CLI.prettyJSON(o)]], "structuredContent": o]
    }
    static func error(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]], "isError": true] }
}

// MARK: - child processes

/// This executable run as a command.
struct Child {
    var status: Int32
    var stdout: String
    var stderr: String

    /// The result JSON (the last line of stdout).
    var result: [String: Any]? {
        guard let line = stdout.split(separator: "\n").last,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return obj
    }

    var errorText: String {
        if let e = result?["error"] as? String { return e }
        let tail = stderr.split(separator: "\n").suffix(5).joined(separator: "\n")
        return tail.isEmpty ? "NTSCRT exited with status \(status)." : tail
    }

    static var executable: URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }

    static func run(_ args: [String]) async throws -> Child {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let outData = Collector(out.fileHandleForReading)
        let errData = Collector(err.fileHandleForReading)
        let status: Int32 = try await withCheckedThrowingContinuation { c in
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
        return Child(status: status, stdout: outData.finish(), stderr: errData.finish())
    }
}

/// Reads a pipe to the end on its own thread, so a child never blocks on a
/// full pipe.
final class Collector: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)
    private let onLine: (@Sendable (String) -> Void)?

    init(_ handle: FileHandle, onLine: (@Sendable (String) -> Void)? = nil) {
        self.onLine = onLine
        Thread.detachNewThread { [self] in
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                if let onLine {
                    pending.append(chunk)
                    while let nl = pending.firstIndex(of: 0x0A) {
                        onLine(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                        pending.removeSubrange(pending.startIndex...nl)
                    }
                }
            }
            done.signal()
        }
    }

    func finish() -> String {
        done.wait()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - render jobs

@MainActor
final class Jobs {
    static let shared = Jobs()
    private(set) var jobs: [String: Job] = [:]
    /// Renders run one at a time: each uses the GPU flat out.
    private var queue: [Job] = []
    private var running: Job?

    func start(args: [String], output: String, plan: Any?, cleanup: URL) -> Job {
        let job = Job(id: String(UUID().uuidString.prefix(8)).lowercased(), args: args,
                      output: output, plan: plan, cleanup: cleanup)
        jobs[job.id] = job
        queue.append(job)
        next()
        return job
    }

    private func next() {
        guard running == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        running = job
        Task {
            await job.run()
            running = nil
            next()
        }
    }

    func cancelAll() {
        for j in jobs.values { j.process?.terminate() }
    }
}

@MainActor
final class Job {
    let id: String
    let args: [String]
    let output: String
    let plan: Any?
    let cleanup: URL
    var state = "queued"
    var progress: Double = 0
    var eta: Double?
    var result: [String: Any]?
    var errorText: String?
    var process: Process?
    let started = Date()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(id: String, args: [String], output: String, plan: Any?, cleanup: URL) {
        self.id = id; self.args = args; self.output = output; self.plan = plan; self.cleanup = cleanup
    }

    var finished: Bool { state == "done" || state == "failed" }

    var status: [String: Any] {
        var s: [String: Any] = ["job_id": id, "state": state, "output": output]
        if let plan { s["plan"] = plan }
        switch state {
        case "running":
            s["progress"] = CLI.decimal(progress)
            if let eta { s["seconds_left"] = CLI.decimal(eta, places: 0) }
            s["next"] = "Call ntscrt_render_status with this job_id to wait for it."
        case "queued":
            s["next"] = "Waiting for another render to finish; call ntscrt_render_status to wait."
        case "done":
            if let r = result {
                s["outputs"] = r["outputs"]
                s["look"] = r["look"]
                if let w = r["warnings"] { s["warnings"] = w }
                if let e = LookSettings.number(r["elapsed"]) { s["elapsed"] = CLI.decimal(e, places: 1) }
            }
        default:
            s["error"] = errorText ?? "The render failed."
        }
        return s
    }

    func run() async {
        state = "running"
        let p = Process()
        p.executableURL = Child.executable
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        process = p
        let outData = Collector(out.fileHandleForReading)
        let errData = Collector(err.fileHandleForReading) { [weak self] line in
            guard line.hasPrefix("{\"eta\"") || line.hasPrefix("{\"progress\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
            let progress = LookSettings.number(obj["progress"])
            let eta = LookSettings.number(obj["eta"])
            Task { @MainActor in
                if let progress { self?.progress = progress }
                if let eta { self?.eta = eta }
            }
        }
        let status: Int32 = await withCheckedContinuation { c in
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { c.resume(returning: -1) }
        }
        let child = Child(status: status, stdout: outData.finish(), stderr: errData.finish())
        try? FileManager.default.removeItem(at: cleanup)
        if status == 0, let r = child.result {
            result = r
            progress = 1
            state = "done"
        } else {
            errorText = child.errorText
            state = "failed"
        }
        for w in waiters.values { w.resume() }
        waiters = [:]
    }

    /// Wait until it finishes, or `seconds` pass.
    func wait(seconds: Double) async {
        guard !finished, seconds > 0 else { return }
        let key = UUID()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters[key] = c
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                waiters.removeValue(forKey: key)?.resume()
            }
        }
    }
}
