// crt-smoke: Phase 1 + downscale verifier.
//
// Loads an input image, optionally downscales it, runs the result through a
// single .slangp preset via librashader, writes a PNG.
//
// Usage:
//   crt-smoke <input> <preset.slangp> <output.png> <librashader.dylib> \
//             [outW outH] [downW downH method]
//
// outW/outH default to 1920x1080 (also the viewport for the shader chain).
// If downW/downH/method are given, the input is downscaled to (downW, downH)
// using `method` (nearest|bilinear|bicubic|lanczos|area) before the chain.

import Foundation
import Metal
import MetalKit
import CoreGraphics
import ImageIO
import CrtAppBridge
import CrtCore
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// MARK: - args

// Trailing "--set NAME=VALUE" args (repeatable) override shader parameters
// after chain creation; everything before them is positional as documented.
var positional: [String] = []
var paramOverrides: [(String, Float)] = []
var ntscSettings: String? = nil   // "default" or a settings-JSON path
var ntscDylib: String? = nil
var frameIndex: Int = 1
var argRest = Array(CommandLine.arguments.dropFirst())
while !argRest.isEmpty {
    let a = argRest.removeFirst()
    if a == "--set" {
        guard !argRest.isEmpty else { fputs("--set needs name=value\n", stderr); exit(2) }
        let pair = argRest.removeFirst().split(separator: "=", maxSplits: 1)
        guard pair.count == 2, let v = Float(pair[1]) else {
            fputs("--set needs name=value\n", stderr); exit(2)
        }
        paramOverrides.append((String(pair[0]), v))
    } else if a == "--ntsc" {
        guard !argRest.isEmpty else { fputs("--ntsc needs 'default' or a settings.json path\n", stderr); exit(2) }
        ntscSettings = argRest.removeFirst()
    } else if a == "--ntsc-dylib" {
        guard !argRest.isEmpty else { fputs("--ntsc-dylib needs a path\n", stderr); exit(2) }
        ntscDylib = argRest.removeFirst()
    } else if a == "--frame" {
        guard !argRest.isEmpty, let f = Int(argRest.removeFirst()) else {
            fputs("--frame needs an integer\n", stderr); exit(2)
        }
        frameIndex = f
    } else {
        positional.append(a)
    }
}

guard positional.count >= 4 else {
    fputs("usage: crt-smoke <input.png> <preset.slangp> <output.png> <librashader.dylib> [outW outH] [downW downH method] [--set NAME=VALUE ...]\n", stderr)
    exit(2)
}
let inputPath  = positional[0]
let presetPath = positional[1]
let outputPath = positional[2]
let dylibPath  = positional[3]
let outW = positional.count > 4 ? Int(positional[4]) ?? 1920 : 1920
let outH = positional.count > 5 ? Int(positional[5]) ?? 1080 : 1080
let downW: Int? = positional.count > 6 ? Int(positional[6]) : nil
let downH: Int? = positional.count > 7 ? Int(positional[7]) : nil
let downMethod: DownscaleMethod? = positional.count > 8 ? DownscaleMethod(rawValue: positional[8]) : nil

// MARK: - load librashader

do {
    try LRShaderChain.loadLibrary(dylibPath)
} catch {
    fputs("loadLibrary failed: \(error.localizedDescription)\n", stderr)
    exit(3)
}

// MARK: - Metal setup

guard let device = MTLCreateSystemDefaultDevice() else {
    fputs("no Metal device\n", stderr); exit(4)
}
guard let queue = device.makeCommandQueue() else {
    fputs("no command queue\n", stderr); exit(5)
}

// MARK: - load input PNG -> MTLTexture

func loadTexture(_ path: String, device: MTLDevice) throws -> MTLTexture {
    let url = URL(fileURLWithPath: path)
    let loader = MTKTextureLoader(device: device)
    let opts: [MTKTextureLoader.Option: Any] = [
        .textureUsage:        NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        .textureStorageMode:  NSNumber(value: MTLStorageMode.private.rawValue),
        .SRGB:                NSNumber(value: false),
        .origin:              MTKTextureLoader.Origin.topLeft.rawValue,
    ]
    return try loader.newTexture(URL: url, options: opts)
}

let inputTex: MTLTexture
do {
    inputTex = try loadTexture(inputPath, device: device)
    print("input texture: \(inputTex.width)x\(inputTex.height) format=\(inputTex.pixelFormat.rawValue)")
} catch {
    fputs("loadTexture failed: \(error)\n", stderr); exit(6)
}

// MARK: - allocate output MTLTexture

let outDesc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm,
    width: outW, height: outH, mipmapped: false
)
outDesc.usage = [.renderTarget, .shaderRead, .shaderWrite]
outDesc.storageMode = .private
guard let outputTex = device.makeTexture(descriptor: outDesc) else {
    fputs("makeTexture(output) failed\n", stderr); exit(7)
}

// MARK: - create chain + render

let chain: LRShaderChain
do {
    chain = try LRShaderChain(presetPath: presetPath, commandQueue: queue)
} catch {
    fputs("chain init failed: \(error.localizedDescription)\n", stderr); exit(8)
}

print("preset loaded; runtime params: \(chain.parameters().count)")
for p in chain.parameters() {
    print("  - \(p.name) [\(p.minimum)..\(p.maximum) step \(p.step), default \(p.initial)]: \(p.desc)")
}

// Phase 1 verification step 4: exercise the parameter setter on the first param.
if let firstParam = chain.parameters().first {
    let testValue = (firstParam.minimum + firstParam.maximum) / 2
    do {
        try chain.setParameter(firstParam.name, value: testValue)
        let readback = chain.parameterValue(firstParam.name)
        print("set/get \(firstParam.name): wrote \(testValue), read back \(readback)")
    } catch {
        fputs("setParameter failed: \(error.localizedDescription)\n", stderr); exit(11)
    }
}

for (name, value) in paramOverrides {
    do {
        try chain.setParameter(name, value: value)
        print("override \(name) = \(value)")
    } catch {
        fputs("override \(name) failed: \(error.localizedDescription)\n", stderr); exit(20)
    }
}

guard let cb = queue.makeCommandBuffer() else {
    fputs("commandBuffer failed\n", stderr); exit(9)
}
var chainCb = cb

// Optional ntsc-rs stage: CPU-process the FULL-RESOLUTION input, then the
// downscale below crunches the degraded signal for the shader
// (NTSC full res -> downscale -> CRT).
var ntscSource = inputTex
if let ntscSettings {
    // Load the capi dylib (explicit flag, else sibling of librashader's Vendor dir).
    let capiPath = ntscDylib
        ?? URL(fileURLWithPath: dylibPath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ntscrs-capi/ntscrs_capi.dylib").path
    do {
        try NTSCFilter.loadLibrary(capiPath)
    } catch {
        fputs("ntsc loadLibrary failed (\(capiPath)): \(error.localizedDescription)\n", stderr); exit(21)
    }
    guard let filter = NTSCFilter() else {
        fputs("NTSCFilter init failed\n", stderr); exit(21)
    }
    if ntscSettings != "default" {
        guard let json = try? String(contentsOfFile: ntscSettings, encoding: .utf8) else {
            fputs("cannot read ntsc settings: \(ntscSettings)\n", stderr); exit(22)
        }
        do {
            try filter.setSettingsJSON(json)
        } catch {
            fputs("ntsc settings parse failed: \(error.localizedDescription)\n", stderr); exit(22)
        }
    }

    // CPU-visible copy of the full-res input. Discrete-GPU Macs need
    // .managed storage + a synchronize blit for the CPU to see GPU writes
    // (.shared is only coherent on unified memory; synchronize is illegal
    // on .shared and Metal validation aborts).
    let w = inputTex.width, h = inputTex.height
    let readDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: inputTex.pixelFormat, width: w, height: h, mipmapped: false)
    readDesc.usage = [.shaderRead]
    let forceManaged = ProcessInfo.processInfo.environment["CRT_FORCE_MANAGED"] != nil
    readDesc.storageMode = (device.hasUnifiedMemory && !forceManaged) ? .shared : .managed
    guard let roundTrip = device.makeTexture(descriptor: readDesc),
          let copyBlit = cb.makeBlitCommandEncoder() else {
        fputs("ntsc staging alloc failed\n", stderr); exit(23)
    }
    copyBlit.copy(from: inputTex,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: roundTrip,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    if roundTrip.storageMode == .managed {
        copyBlit.synchronize(resource: roundTrip)
    }
    copyBlit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    if let err = cb.error {
        fputs("ntsc blit command buffer error: \(err)\n", stderr); exit(25)
    }

    let rowBytes = w * 4
    var bytes = [UInt8](repeating: 0, count: rowBytes * h)
    let fullRegion = MTLRegionMake2D(0, 0, w, h)
    bytes.withUnsafeMutableBytes { raw in
        roundTrip.getBytes(raw.baseAddress!, bytesPerRow: rowBytes, from: fullRegion, mipmapLevel: 0)
        guard filter.processBGRA8(raw.baseAddress!, width: UInt(w), height: UInt(h),
                                  rowBytes: UInt(rowBytes), frameIndex: frameIndex) else {
            fputs("ntsc process failed\n", stderr); exit(24)
        }
    }
    // replace() is CPU->GPU coherent for both shared and managed textures.
    roundTrip.replace(region: fullRegion, mipmapLevel: 0, withBytes: bytes, bytesPerRow: rowBytes)
    print("ntsc stage applied at full res (\(w)x\(h), frame \(frameIndex), settings: \(ntscSettings))")

    ntscSource = roundTrip
    guard let newCb = queue.makeCommandBuffer() else {
        fputs("commandBuffer failed\n", stderr); exit(9)
    }
    chainCb = newCb
}

// Optional downscale pre-pass (after the NTSC stage, if any).
let finalChainInput: MTLTexture
if let dw = downW, let dh = downH, let method = downMethod {
    let downDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: ntscSource.pixelFormat,
        width: dw, height: dh, mipmapped: false
    )
    downDesc.usage = [.shaderRead, .shaderWrite]
    downDesc.storageMode = .private
    guard let downTex = device.makeTexture(descriptor: downDesc) else {
        fputs("makeTexture(downscale) failed\n", stderr); exit(18)
    }
    do {
        let ds = try Downscaler(device: device)
        ds.encode(into: chainCb, source: ntscSource, destination: downTex, method: method)
        print("downscaled \(ntscSource.width)x\(ntscSource.height) -> \(dw)x\(dh) via \(method.rawValue)")
        finalChainInput = downTex
    } catch {
        fputs("downscaler init failed: \(error.localizedDescription)\n", stderr); exit(19)
    }
} else {
    finalChainInput = ntscSource
}

let viewport = MTLViewport(originX: 0, originY: 0, width: Double(outW), height: Double(outH), znear: 0, zfar: 1)
do {
    try chain.renderInputTexture(finalChainInput, outputTexture: outputTex, viewport: viewport, frameCount: UInt(max(0, frameIndex)), commandBuffer: chainCb)
} catch {
    fputs("render failed: \(error.localizedDescription)\n", stderr); exit(10)
}

// Blit output to a shared-storage staging texture so we can read it back.
let stagingDesc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: outW, height: outH, mipmapped: false
)
stagingDesc.usage = [.shaderRead]
stagingDesc.storageMode = (device.hasUnifiedMemory
    && ProcessInfo.processInfo.environment["CRT_FORCE_MANAGED"] == nil) ? .shared : .managed
guard let staging = device.makeTexture(descriptor: stagingDesc) else {
    fputs("makeTexture(staging) failed\n", stderr); exit(11)
}
guard let blit = chainCb.makeBlitCommandEncoder() else {
    fputs("blit encoder failed\n", stderr); exit(12)
}
blit.copy(from: outputTex,
          sourceSlice: 0, sourceLevel: 0,
          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
          sourceSize: MTLSize(width: outW, height: outH, depth: 1),
          to: staging,
          destinationSlice: 0, destinationLevel: 0,
          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
// Discrete-GPU Macs: managed staging needs a synchronize blit before the
// CPU reads it (synchronize is illegal on .shared — validation aborts).
if staging.storageMode == .managed {
    blit.synchronize(resource: staging)
}
blit.endEncoding()
chainCb.commit()
chainCb.waitUntilCompleted()
if let err = chainCb.error {
    fputs("command buffer error: \(err)\n", stderr); exit(13)
}

// MARK: - read back -> PNG

let bytesPerRow = outW * 4
let region = MTLRegionMake2D(0, 0, outW, outH)
var pixels = [UInt8](repeating: 0, count: outH * bytesPerRow)
pixels.withUnsafeMutableBytes { raw in
    staging.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let bmInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
    fputs("CGDataProvider failed\n", stderr); exit(14)
}
guard let cgImage = CGImage(
    width: outW, height: outH,
    bitsPerComponent: 8, bitsPerPixel: 32,
    bytesPerRow: bytesPerRow,
    space: cs, bitmapInfo: CGBitmapInfo(rawValue: bmInfo),
    provider: provider, decode: nil, shouldInterpolate: false,
    intent: .defaultIntent
) else {
    fputs("CGImage failed\n", stderr); exit(15)
}

let outURL = URL(fileURLWithPath: outputPath) as CFURL
let pngType: CFString = {
    if #available(macOS 11.0, *) { return UTType.png.identifier as CFString }
    return "public.png" as CFString
}()
guard let dest = CGImageDestinationCreateWithURL(outURL, pngType, 1, nil) else {
    fputs("CGImageDestination failed\n", stderr); exit(16)
}
CGImageDestinationAddImage(dest, cgImage, nil)
if !CGImageDestinationFinalize(dest) {
    fputs("CGImageDestination finalize failed\n", stderr); exit(17)
}

print("wrote \(outputPath) (\(outW)x\(outH))")
