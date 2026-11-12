// The Mac reference for ntscrt-codec's parity check: compiled together with
// the Mac app's own Sources/CrtCodec/*.swift (unmodified) by ref/build.sh,
// so everything here runs the Mac's code exactly as the app does.
//
//   ntscrt-codec-ref tables                 the float tables the port embeds
//   ntscrt-codec-ref run <cases.json> <dir> every case, outputs to <dir>/<name>.rgba
//                                           ("/" in a name becomes "__")
//
// Inputs are generated with integer math only, identically in
// examples/parity.rs. Outputs are written as RGBA (the port's order).

import Foundation

func hex(_ v: [Float]) -> String {
    v.map { String(format: "0x%08x", $0.bitPattern) }.joined(separator: ", ")
}

// MARK: - inputs (keep in step with examples/parity.rs)

/// RGB of pattern `name` at (x, y) of frame n.
func patternPixel(_ name: String, x: Int, y: Int, n: Int, w: Int, h: Int, cut: Int?) -> (Int, Int, Int) {
    let scene = (cut.map { n >= $0 } ?? false) ? 1 : 0
    func tex(_ a: Int, _ b: Int) -> Int { ((a * 7919 + b * 104_729) ^ (a * b)) % 31 }
    var r = 0, g = 0, b = 0
    switch name {
    case "square":
        // DigitalVideoTests' clip, at any size.
        if scene == 0 {
            r = (x * 255) / w
            g = ((x / 8 + y / 8) % 2) * 120 + 40
            b = (y * 255) / h
        } else {
            r = 200 - (y * 150) / h
            g = ((x / 16) % 2) * 60 + 90
            b = 60 + (x * 120) / w
        }
        let sx = 20 + 4 * n, sy = 60 + 2 * n
        if x >= sx, x < sx + 40, y >= sy, y < sy + 40 { r = 250; g = 240; b = 30 }
    case "clip":
        // Something closer to footage: gradients, texture, a slow pan, a
        // moving round subject, a dark corner.
        let px = x + 3 * n
        if scene == 0 {
            r = 40 + (px * 160) / (w + 1) % 160 + tex(px / 3, y / 3) % 24
            g = 60 + ((px + y) % 64) * 2
            b = 200 - (y * 150) / h + tex(y / 2, px / 5) % 20
        } else {
            r = 120 + tex(px / 2, y / 2) % 31 * 3
            g = 30 + (y * 180) / h
            b = 90 + ((px / 6) % 2) * 50
        }
        let cx = w / 3 + 5 * n, cy = h / 2 + (n % 7) * 3, rad = h / 5
        if (x - cx) * (x - cx) + (y - cy) * (y - cy) < rad * rad { r = 230; g = 196; b = 170 }
        if x < w / 3 && y > (2 * h) / 3 { r = r * 3 / 10; g = g * 3 / 10; b = b * 3 / 10 }
    case "stripes":
        // Fine stripes, finer than the camera can hold.
        let v = (x * 3) % 7 < 3 ? 228 : 28
        r = v; g = v; b = v
        if (y / 16) % 2 == 1 { g = 255 - v }
    case "night":
        // A lit subject in a black frame.
        r = 18 + tex(x, y + n) % 6; g = r; b = r + 4
        if abs(x - w / 2) < w / 5 && abs(y - h / 2) < h / 3 { r = 236; g = 214; b = 190 }
    default:
        fatalError("pattern \(name)")
    }
    return (min(255, max(0, r)), min(255, max(0, g)), min(255, max(0, b)))
}

/// Frame n as BGRA (the Mac's order).
/// Frame n as BGRA (the Mac's order). A name ending "+1" is that pattern
/// with one pixel in 200 moved by one code value (green) — to measure how
/// far the codec itself carries differences as small as the resampler's.
func patternBGRA(_ name: String, n: Int, w: Int, h: Int, cut: Int?) -> [UInt8] {
    let perturb = name.hasSuffix("+1")
    let base = perturb ? String(name.dropLast(2)) : name
    var px = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let (r, g, b) = patternPixel(base, x: x, y: y, n: n, w: w, h: h, cut: cut)
            let i = (y * w + x) * 4
            px[i] = UInt8(b); px[i + 1] = UInt8(g); px[i + 2] = UInt8(r)
        }
    }
    if perturb {
        // About one pixel in 200, as many as the resampler stand-in misses.
        for y in 0..<h {
            for x in 0..<w where (x * 7919 + y * 104_729 + n * 31) % 200 == 0 {
                let i = (y * w + x) * 4 + 1
                px[i] = px[i] == 255 ? 254 : px[i] + 1
            }
        }
    }
    return px
}

func toRGBA(_ bgra: [UInt8]) -> [UInt8] {
    var o = bgra
    for i in stride(from: 0, to: o.count, by: 4) { o[i] = bgra[i + 2]; o[i + 2] = bgra[i] }
    return o
}

// MARK: - cases

struct Case {
    let name: String
    let kind: String
    let src: (Int, Int)
    let cap: (Int, Int)
    let fps: Double
    let pattern: String
    let cut: Int?
    let settings: DigitalSettings
    let history: String?
    let calls: [Int]
    let fresh: Bool
    let still: Bool
}

func parseCases(_ path: String) -> [Case] {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    return (root["cases"] as! [[String: Any]]).map { c in
        let src = c["src"] as! [Int], cap = c["cap"] as? [Int] ?? src
        var values: [String: Double] = [:]
        switch c["base"] as? String {
        case "starting": values = DigitalParam.startingValues
        default: break
        }
        if let f = c["format"] as? String { values.merge(DigitalFormat.byID[f]!.values) { _, n in n } }
        for (k, v) in c["settings"] as? [String: Double] ?? [:] { values[k] = v }
        var calls: [Int] = []
        if let play = c["play"] as? Int { calls += Array(0..<play) }
        calls += c["calls"] as? [Int] ?? []
        return Case(name: c["name"] as! String, kind: c["kind"] as? String ?? "process",
                    src: (src[0], src[1]), cap: (cap[0], cap[1]),
                    fps: c["fps"] as? Double ?? 30, pattern: c["pattern"] as? String ?? "square",
                    cut: c["cut"] as? Int, settings: DigitalSettings(values: values),
                    history: c["history"] as? String, calls: calls,
                    fresh: c["fresh"] as? Bool ?? false, still: c["still"] as? Bool ?? false)
    }
}

func history(_ name: String?, base: DigitalSettings) -> DigitalHistory? {
    switch name {
    case nil: return nil
    case "ramp":
        // DigitalVideoTests.testKeyframedSettingsLookTheSameJumpedTo's.
        return DigitalHistory(id: 7) { n in
            var s = base
            s.values["quality"] = 0.1 + 0.02 * Double(n)
            s.values["data_loss"] = n > 15 ? 0.5 : 0
            return s
        }
    case "fade":
        // Picture controls and noise moving over time.
        return DigitalHistory(id: 11) { n in
            var s = base
            s.values["sensor_noise"] = 0.05 * Double(n % 9)
            s.values["saturation"] = 0.6 + 0.05 * Double(n)
            s.values["sharpening"] = n > 10 ? 0.7 : 0.2
            return s
        }
    default: fatalError("history \(name!)")
    }
}

func run(_ c: Case) -> [UInt8] {
    var out: [UInt8] = []
    let (w, h) = c.src
    switch c.kind {
    case "scale":
        for n in c.calls {
            var px = patternBGRA(c.pattern, n: n, w: w, h: h, cut: c.cut)
            let small = px.withUnsafeMutableBytes {
                DigitalVideoRenderer.scale($0.baseAddress!, width: w, height: h,
                                           rowBytes: w * 4, to: c.cap, optics: c.settings)
            }
            out += toRGBA(small)
        }
    case "process":
        let hist = history(c.history, base: c.settings)
        var renderer = DigitalVideoRenderer()
        let visitor: DigitalFrameVisitor = { i, body in
            let f = patternBGRA(c.pattern, n: i, w: w, h: h, cut: c.cut)
            f.withUnsafeBytes { body($0.baseAddress!, w, h, w * 4) }
            return true
        }
        for n in c.calls {
            if c.fresh { renderer = DigitalVideoRenderer() }
            var px = patternBGRA(c.pattern, n: c.still ? 0 : n, w: w, h: h, cut: c.cut)
            px.withUnsafeMutableBytes {
                renderer.process(frame: n, pixels: $0.baseAddress!, width: w, height: h, rowBytes: w * 4,
                                 captureSize: c.cap, sourceFPS: c.fps, settings: c.settings,
                                 history: hist, earlier: c.still ? nil : visitor)
            }
            out += toRGBA(px)
        }
    default:
        fatalError("kind \(c.kind)")
    }
    return out
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "tables":
    print("DCT_BASIS: \(hex(DigitalCodec.basis))")
    print("SRGB_TO_LINEAR: \(hex(DigitalVideoRenderer.srgbToLinear))")
case "run":
    let cases = parseCases(args[2])
    let dir = URL(fileURLWithPath: args[3])
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let only = args.count > 4 ? Set(args[4...]) : nil
    for c in cases where only?.contains(c.name) ?? true {
        let t0 = Date()
        let bytes = run(c)
        let file = c.name.replacingOccurrences(of: "/", with: "__") + ".rgba"
        try! Data(bytes).write(to: dir.appendingPathComponent(file))
        print(String(format: "%@: %d outputs, %.2f s", c.name, c.calls.count, Date().timeIntervalSince(t0)))
    }
default:
    print("usage: ntscrt-codec-ref tables | run <cases.json> <outdir> [case…]")
    exit(2)
}
