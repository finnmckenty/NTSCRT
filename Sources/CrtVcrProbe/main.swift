// crt-vcr-probe: render frames through the glitch stage (TV + VCR) headless,
// for judging the tape simulation by eye and timing it.
//
// Usage:
//   crt-vcr-probe <input.png> <out.png> [--size W H] [--frames N] [--fps F]
//                 [--start T] [--cols C] [--scale S] [key=value ...]
//
// key=value pairs are glitch knobs (GlitchParam ids), e.g. vcr=1 tape_mold=0.7.
// Frames play in order from --start, so the heads' history carries over;
// they are tiled into one contact sheet, --cols across.

import Foundation
import Metal
import CoreGraphics
import CrtCore

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    fputs("usage: crt-vcr-probe <input.png> <out.png> [--size W H] [--frames N] [--fps F] [--start T] [--cols C] [--scale S] [key=value ...]\n", stderr)
    exit(2)
}
let input = URL(fileURLWithPath: args.removeFirst())
let output = URL(fileURLWithPath: args.removeFirst())
var W = 640, H = 480, frames = 1, fps = 29.97, start = 1.0, cols = 1, scale = 1
var crop: (x: Int, y: Int, w: Int, h: Int)? = nil
var sweep: (key: String, values: [Double])? = nil
var values: [String: Double] = [:]
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--size": W = Int(args.removeFirst())!; H = Int(args.removeFirst())!
    case "--frames": frames = Int(args.removeFirst())!
    case "--fps": fps = Double(args.removeFirst())!
    case "--start": start = Double(args.removeFirst())!
    case "--cols": cols = Int(args.removeFirst())!
    case "--scale": scale = Int(args.removeFirst())!
    case "--pickers":
        // Every Tape picker condition (rows) in every Deck picker condition
        // (columns).
        sweep = ("__pickers", [])
    case "--sweep":
        let k = args.removeFirst()
        sweep = (k, args.removeFirst().split(separator: ",").map { Double($0)! })
    case "--crop": crop = (Int(args.removeFirst())!, Int(args.removeFirst())!, Int(args.removeFirst())!, Int(args.removeFirst())!)
    default:
        let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2, let v = Double(kv[1]) else { fputs("bad arg \(a)\n", stderr); exit(2) }
        values[kv[0]] = v
    }
}

let context = try MetalContext()
let device = context.device
let source = try loadTexture(url: input, device: device)
var renderer = try GlitchRenderer(context: context)
let spec = DownscaleSpec(width: W, height: H, method: .area)

if let sw = sweep {
    frames = sw.key == "__pickers" ? VcrCondition.tapes.count * VcrCondition.decks.count : sw.values.count
    if sw.key == "__pickers" { cols = VcrCondition.decks.count }
}
let rows = (frames + cols - 1) / cols
let cw = crop?.w ?? W, ch = crop?.h ?? H, cx = crop?.x ?? 0, cy = crop?.y ?? 0
let sheetW = cw * scale * cols, sheetH = ch * scale * rows
var sheet = [UInt8](repeating: 0, count: sheetW * sheetH * 4)
let staging = makeStagingTexture(device: device, width: W, height: H)!
var settings = GlitchSettings(values: values)
var gpuTimes: [Double] = []
var cpuTimes: [Double] = []
for f in 0..<frames {
    var t = start + Double(f) / fps
    if let sw = sweep {
        var v = values
        if sw.key == "__pickers" {
            let tape = VcrCondition.tapes[f / VcrCondition.decks.count], deck = VcrCondition.decks[f % VcrCondition.decks.count]
            v = deck.applied(to: tape.applied(to: v, keys: VcrCondition.tapeKeys), keys: VcrCondition.deckKeys)
        } else { v[sw.key] = sw.values[f] }
        settings = GlitchSettings(values: v)
        renderer = try GlitchRenderer(context: context)
        t = start
    }
    let cb = context.queue.makeCommandBuffer()!
    let down = try renderer.downscaled(source, spec: spec, commandBuffer: cb)
    let c0 = Date()
    let out = try renderer.encode(into: cb, chainInput: down, time: t, settings: settings)
    cpuTimes.append(Date().timeIntervalSince(c0))
    let blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: out, to: staging)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    gpuTimes.append(cb.gpuEndTime - cb.gpuStartTime)
    var px = [UInt8](repeating: 0, count: W * H * 4)
    staging.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    let ox = (f % cols) * cw * scale, oy = (f / cols) * ch * scale
    for y in 0..<(ch * scale) { for x in 0..<(cw * scale) {
        let s = ((cy + y / scale) * W + cx + x / scale) * 4
        let d = ((oy + y) * sheetW + ox + x) * 4
        sheet[d] = px[s]; sheet[d + 1] = px[s + 1]; sheet[d + 2] = px[s + 2]; sheet[d + 3] = 255
    } }
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: &sheet, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: sheetW * 4,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
try writePNG(ctx.makeImage()!, to: output)
func ms(_ a: [Double]) -> String {
    let s = a.dropFirst().sorted()
    guard !s.isEmpty else { return String(format: "%.2f", (a.first ?? 0) * 1000) }
    return String(format: "median %.2f max %.2f", s[s.count / 2] * 1000, s.last! * 1000)
}
print("frames \(frames)  cpu ms \(ms(cpuTimes))  gpu ms \(ms(gpuTimes))")

// CRT_VCR_DUMP=1: the tape along the last frame's track, and the heads.
if ProcessInfo.processInfo.environment["CRT_VCR_DUMP"] == "1", let plan = renderer.lastPlan, let v = plan.vcr {
    let t = TapeParams(settings)
    for y in Array(stride(from: 0, to: v.lines.count, by: max(1, v.lines.count / 12))) + Array(max(0, v.lines.count - 14)..<v.lines.count) {
        let l = v.lines[y]
        var s = String(format: "row %3d head %d spacing %.3f grease %.3f gain %.3f |", y, l.head, l.spacing, l.grease, l.gain)
        for k in 0..<6 {
            let u = 9.4 + Double(k) * 10
            let along = Double(l.along0) + u / NTSCTiming.line * TapeGeometry.lineLength
            let x = Double(l.originBase) / 10 + Double(l.originOffset) / 10 + along * cos(TapeGeometry.angle)
            let p = TapeSurface.at(TapePosition(x: x, y: TapeGeometry.trackStart + along * sin(TapeGeometry.angle)), t)
            s += String(format: " %.2f/%.2f/%.2f", p.lift, p.film, p.output)
        }
        print(s)
    }
}
if ProcessInfo.processInfo.environment["CRT_VCR_ROWS"] == "1", let plan = renderer.lastPlan {
    var s = ""
    for y in stride(from: 0, to: plan.rows.count, by: 16) {
        let r = plan.rows[y]
        s += String(format: "%d:%.1f/%d/%.2f ", y, r.u0, r.fieldLine, r.burstScale)
    }
    print(s)
}
// CRT_VCR_MEASURE=1: luma noise (IRE RMS) over the middle of the last frame.
if ProcessInfo.processInfo.environment["CRT_VCR_MEASURE"] == "1" {
    var ys: [Double] = []
    let ox = (frames - 1) % cols * cw * scale, oy = (frames - 1) / cols * ch * scale
    for y in (ch * scale / 4)..<(ch * scale * 3 / 4) { for x in (cw * scale / 4)..<(cw * scale * 3 / 4) {
        let i = ((oy + y) * sheetW + ox + x) * 4
        ys.append(0.299 * Double(sheet[i + 2]) + 0.587 * Double(sheet[i + 1]) + 0.114 * Double(sheet[i]))
    } }
    let m = ys.reduce(0, +) / Double(ys.count)
    let sd = (ys.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(ys.count)).squareRoot()
    print(String(format: "luma mean %.1f/255  noise %.2f IRE RMS  (S/N %.1f dB re 100 IRE)", m, sd / 255 * 92.5,
                 20 * log10(100 / max(1e-6, sd / 255 * 92.5))))
}
