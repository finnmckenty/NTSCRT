// crt-sweep: parameter-effect measurement.
//
// For each preset, renders the default output once, then re-renders with each
// runtime parameter pushed to its min and max, and reports the mean absolute
// pixel difference vs the default render. Parameters whose extremes produce
// ~zero difference are objectively dead in this pipeline; near-zero are weak.
// Zero-diff params get a second chance at frameCount 37 to detect
// animation-dependent effects (interlacing, animated artifacts).
//
// Also reports duplicate #pragma parameter declarations that disagree on
// range/default across passes (the UI keeps the first declaration).
//
// Usage:
//   crt-sweep <input.png> <slang-shaders-root> <librashader.dylib> \
//             [--out W H] [--down W H method|--no-down] [--presets id1,id2]
//
// Defaults: --out 1920 1080, --down 256 224 area (the app's defaults).

import Foundation
import Metal
import MetalKit
import CrtAppBridge
import CrtCore

// MARK: - args

var rest = Array(CommandLine.arguments.dropFirst())
guard rest.count >= 3 else {
    fputs("""
    usage: crt-sweep <input.png> <slang-shaders-root> <librashader.dylib> \\
                     [--out W H] [--down W H method|--no-down] [--presets id1,id2]
    """ + "\n", stderr)
    exit(2)
}
let inputPath = rest.removeFirst()
let presetsRootPath = rest.removeFirst()
let dylibPath = rest.removeFirst()

var outW = 1920, outH = 1080
var downSpec: (Int, Int, DownscaleMethod)? = (256, 224, .area)
var presetFilter: Set<String>? = nil
var overrides: [(String, Float)] = []

while !rest.isEmpty {
    let flag = rest.removeFirst()
    switch flag {
    case "--out":
        guard rest.count >= 2, let w = Int(rest.removeFirst()), let h = Int(rest.removeFirst()) else {
            fputs("--out needs W H\n", stderr); exit(2)
        }
        outW = w; outH = h
    case "--down":
        guard rest.count >= 3, let w = Int(rest.removeFirst()), let h = Int(rest.removeFirst()),
              let m = DownscaleMethod(rawValue: rest.removeFirst()) else {
            fputs("--down needs W H method\n", stderr); exit(2)
        }
        downSpec = (w, h, m)
    case "--no-down":
        downSpec = nil
    case "--presets":
        guard !rest.isEmpty else { fputs("--presets needs ids\n", stderr); exit(2) }
        presetFilter = Set(rest.removeFirst().split(separator: ",").map(String.init))
    case "--set":
        // name=value applied before the baseline render (and kept for the
        // whole sweep) — used to open gates like CURVATURE=1.
        guard !rest.isEmpty else { fputs("--set needs name=value\n", stderr); exit(2) }
        let pair = rest.removeFirst().split(separator: "=", maxSplits: 1)
        guard pair.count == 2, let v = Float(pair[1]) else {
            fputs("--set needs name=value\n", stderr); exit(2)
        }
        overrides.append((String(pair[0]), v))
    default:
        fputs("unknown flag \(flag)\n", stderr); exit(2)
    }
}

// MARK: - Metal + input setup

do { try LRShaderChain.loadLibrary(dylibPath) } catch {
    fputs("loadLibrary failed: \(error.localizedDescription)\n", stderr); exit(3)
}
guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue() else {
    fputs("Metal setup failed\n", stderr); exit(4)
}

let inputTex: MTLTexture
do {
    let loader = MTKTextureLoader(device: device)
    inputTex = try loader.newTexture(URL: URL(fileURLWithPath: inputPath), options: [
        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        .SRGB: NSNumber(value: false),
        .origin: MTKTextureLoader.Origin.topLeft.rawValue,
    ])
} catch {
    fputs("input load failed: \(error)\n", stderr); exit(5)
}

// Optional downscale, done once — every render reuses the same chain input.
let chainInput: MTLTexture
if let (dw, dh, method) = downSpec {
    let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: inputTex.pixelFormat, width: dw, height: dh, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]
    d.storageMode = .private
    guard let downTex = device.makeTexture(descriptor: d),
          let cb = queue.makeCommandBuffer() else {
        fputs("downscale setup failed\n", stderr); exit(6)
    }
    do {
        let ds = try Downscaler(device: device)
        ds.encode(into: cb, source: inputTex, destination: downTex, method: method)
    } catch {
        fputs("downscaler failed: \(error)\n", stderr); exit(6)
    }
    cb.commit(); cb.waitUntilCompleted()
    chainInput = downTex
    print("input: \(inputTex.width)x\(inputTex.height) -> \(dw)x\(dh) (\(method.rawValue)), output \(outW)x\(outH)")
} else {
    chainInput = inputTex
    print("input: \(inputTex.width)x\(inputTex.height) (no downscale), output \(outW)x\(outH)")
}

// Shared render targets, reused across all renders.
let outDesc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: outW, height: outH, mipmapped: false)
outDesc.usage = [.renderTarget, .shaderRead, .shaderWrite]
outDesc.storageMode = .private
let stagingDesc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: outW, height: outH, mipmapped: false)
stagingDesc.usage = [.shaderRead]
stagingDesc.storageMode = .shared
guard let outputTex = device.makeTexture(descriptor: outDesc),
      let staging = device.makeTexture(descriptor: stagingDesc) else {
    fputs("target allocation failed\n", stderr); exit(7)
}
let viewport = MTLViewport(originX: 0, originY: 0,
                           width: Double(outW), height: Double(outH), znear: 0, zfar: 1)
let byteCount = outW * outH * 4
let bytesPerRow = outW * 4
let region = MTLRegionMake2D(0, 0, outW, outH)

func render(_ chain: LRShaderChain, frameCount: UInt, into pixels: inout [UInt8]) -> Bool {
    guard let cb = queue.makeCommandBuffer() else { return false }
    do {
        try chain.renderInputTexture(chainInput, outputTexture: outputTex,
                                     viewport: viewport, frameCount: frameCount,
                                     commandBuffer: cb)
    } catch { return false }
    guard let blit = cb.makeBlitCommandEncoder() else { return false }
    blit.copy(from: outputTex,
              sourceSlice: 0, sourceLevel: 0,
              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: outW, height: outH, depth: 1),
              to: staging,
              destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    if cb.error != nil { return false }
    pixels.withUnsafeMutableBytes { raw in
        staging.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
    }
    return true
}

/// Mean absolute difference over BGR bytes (alpha skipped), normalized to 0...1.
func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var total: UInt64 = 0
    a.withUnsafeBufferPointer { pa in
        b.withUnsafeBufferPointer { pb in
            var i = 0
            while i < byteCount {
                total += UInt64(abs(Int(pa[i]) - Int(pb[i])))       // B
                total += UInt64(abs(Int(pa[i + 1]) - Int(pb[i + 1]))) // G
                total += UInt64(abs(Int(pa[i + 2]) - Int(pb[i + 2]))) // R
                i += 4
            }
        }
    }
    return Double(total) / (Double(outW * outH * 3) * 255.0)
}

func fmtDiff(_ d: Double) -> String {
    d < 0.00005 ? "   0    " : String(format: "%7.4f%%", d * 100)
}

// MARK: - sweep

let presetsRoot = URL(fileURLWithPath: presetsRootPath)
let presets = Presets.all.filter { presetFilter?.contains($0.id) ?? true }

var baseline = [UInt8](repeating: 0, count: byteCount)
var animBaseline = [UInt8](repeating: 0, count: byteCount)
var probe = [UInt8](repeating: 0, count: byteCount)

for preset in presets {
    let path = presetsRoot.appendingPathComponent(preset.relativePath).path
    print("\n== \(preset.displayName) (\(preset.id)) ==")
    let chain: LRShaderChain
    do { chain = try LRShaderChain(presetPath: path, commandQueue: queue) } catch {
        print("  chain failed: \(error.localizedDescription)"); continue
    }

    let raw = chain.parameters()

    // Duplicate declarations disagreeing on bounds/default across passes.
    var byName: [String: LRShaderParam] = [:]
    for p in raw {
        if let first = byName[p.name] {
            if first.minimum != p.minimum || first.maximum != p.maximum
                || first.initial != p.initial || first.step != p.step {
                print("  RANGE CONFLICT \(p.name): [\(first.minimum)..\(first.maximum) step \(first.step) def \(first.initial)] vs [\(p.minimum)..\(p.maximum) step \(p.step) def \(p.initial)]")
            }
        } else {
            byName[p.name] = p
        }
    }
    var seen = Set<String>()
    let params = raw.filter { seen.insert($0.name).inserted }

    // Apply gate overrides; the overridden value becomes the param's
    // "default" for this sweep so exploration happens around the open gate.
    var effectiveInitial: [String: Float] = [:]
    for p in params { effectiveInitial[p.name] = p.initial }
    for (name, value) in overrides where effectiveInitial[name] != nil {
        try? chain.setParameter(name, value: value)
        effectiveInitial[name] = value
        print("  override: \(name) = \(value)")
    }

    guard render(chain, frameCount: 1, into: &baseline) else {
        print("  baseline render failed"); continue
    }
    var haveAnimBaseline = false

    print("  \("param".padding(toLength: 32, withPad: " ", startingAt: 0))  min-diff   max-diff   verdict")
    for p in params where p.maximum > p.minimum {
        let def = effectiveInitial[p.name] ?? p.initial
        func diffAt(_ value: Float) -> Double? {
            guard value != def else { return nil }
            try? chain.setParameter(p.name, value: value)
            guard render(chain, frameCount: 1, into: &probe) else { return nil }
            return meanDiff(probe, baseline)
        }
        let minDiff = diffAt(p.minimum)
        let maxDiff = diffAt(p.maximum)
        try? chain.setParameter(p.name, value: def)
        let best = max(minDiff ?? 0, maxDiff ?? 0)

        var verdict: String
        if best >= 0.005 { verdict = "OK" }
        else if best >= 0.0001 { verdict = "WEAK" }
        else {
            // Dead on a static frame — check whether it matters when animating.
            if !haveAnimBaseline {
                _ = render(chain, frameCount: 37, into: &animBaseline)
                haveAnimBaseline = true
            }
            let extreme = def == p.maximum ? p.minimum : p.maximum
            try? chain.setParameter(p.name, value: extreme)
            _ = render(chain, frameCount: 37, into: &probe)
            try? chain.setParameter(p.name, value: def)
            let animDiff = meanDiff(probe, animBaseline)
            verdict = animDiff >= 0.0001 ? "ANIM-ONLY (\(fmtDiff(animDiff).trimmingCharacters(in: .whitespaces)))" : "DEAD"
        }

        let minStr = minDiff.map(fmtDiff) ?? "  (=def)"
        let maxStr = maxDiff.map(fmtDiff) ?? "  (=def)"
        print("  \(p.name.padding(toLength: 32, withPad: " ", startingAt: 0))  \(minStr)  \(maxStr)  \(verdict)")
    }
}
