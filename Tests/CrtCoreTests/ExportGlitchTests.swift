import XCTest
import Metal
import AVFoundation
import ImageIO
@testable import CrtCore

/// Every exporter applies the glitch stage when asked — and a healthy set
/// changes nothing. Runs with the CRT shader off (the bypass), so it needs
/// no shader library and measures the stage alone.
final class ExportGlitchTests: XCTestCase {

    private var context: MetalContext!
    private var tmp: URL!
    private let size = (w: 640, h: 480)
    private let downscale = DownscaleSpec(width: 320, height: 240, method: .nearest)

    override func setUpWithError() throws {
        context = try MetalContext()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntscrt-glitch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private func source() -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.w,
                                                         height: size.h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = context.device.hasUnifiedMemory ? .shared : .managed
        let t = context.device.makeTexture(descriptor: d)!
        var bytes = [UInt8](repeating: 255, count: size.w * size.h * 4)
        for y in 0..<size.h { for x in 0..<size.w {
            let i = (y * size.w + x) * 4
            bytes[i] = UInt8((x * 255) / size.w); bytes[i + 1] = 150; bytes[i + 2] = UInt8((y * 255) / size.h)
        } }
        t.replace(region: MTLRegionMake2D(0, 0, size.w, size.h), mipmapLevel: 0,
                  withBytes: bytes, bytesPerRow: size.w * 4)
        return t
    }

    private func frame(_ url: URL) async throws -> CGImage {
        if url.pathExtension == "mp4" {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            return try await gen.image(at: CMTime(value: 2, timescale: 12)).image
        }
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 2, nil))
    }

    /// Mean absolute difference of two images, 0–255.
    private func difference(_ a: CGImage, _ b: CGImage) -> Double {
        func pixels(_ img: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
            px.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height,
                                    bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            }
            return px
        }
        let pa = pixels(a), pb = pixels(b)
        var total = 0
        for i in 0..<min(pa.count, pb.count) where i % 4 != 3 { total += abs(Int(pa[i]) - Int(pb[i])) }
        return Double(total) / Double(min(pa.count, pb.count) * 3 / 4)
    }

    private let broken = GlitchSettings(values: ["vertical_hold": 0.7, "horizontal_hold": 0.9])

    func testStillVideoExportAppliesTheGlitchStage() async throws {
        func export(_ glitch: GlitchSettings?, _ name: String) async throws -> CGImage {
            let s = Mp4Exporter.Settings(outputURL: tmp.appendingPathComponent(name),
                                         outputWidth: size.w, outputHeight: size.h,
                                         downscale: downscale, presetPath: "",
                                         shaderEnabled: false, glitch: glitch,
                                         codec: .h264, averageBitrate: 12_000_000)
            try await Mp4Exporter(context: context).exportStill(
                source: source(), totalFrames: 6, fps: 12, paramValues: [:], settings: s,
                progress: { _ in })
            return try await frame(s.outputURL)
        }
        let off = try await export(nil, "off.mp4")
        let healthy = try await export(GlitchSettings(), "healthy.mp4")
        let torn = try await export(broken, "torn.mp4")
        XCTAssertLessThan(difference(off, healthy), 0.5, "a healthy set changes nothing")
        XCTAssertGreaterThan(difference(off, torn), 20, "a broken one changes the picture")
    }

    func testGifExportAppliesTheGlitchStage() async throws {
        func export(_ glitch: GlitchSettings?, _ name: String) async throws -> CGImage {
            let s = GifExporter.Settings(outputURL: tmp.appendingPathComponent(name),
                                         width: size.w, height: size.h, fps: 12,
                                         downscale: downscale, presetPath: "",
                                         shaderEnabled: false, glitch: glitch)
            try await GifExporter(context: context).exportStill(
                source: source(), totalFrames: 4, paramValues: [:], settings: s, progress: { _ in })
            return try await frame(s.outputURL)
        }
        let off = try await export(nil, "off.gif")
        let healthy = try await export(GlitchSettings(), "healthy.gif")
        let torn = try await export(broken, "torn.gif")
        XCTAssertEqual(difference(off, healthy), 0, "a healthy set changes nothing (GIF is exact)")
        XCTAssertGreaterThan(difference(off, torn), 20)
    }

    func testPerFrameKeyframesReachTheGlitchStage() async throws {
        // Keyframed to break only from frame 3 on: early frames match the
        // unglitched export, late ones don't.
        let s = Mp4Exporter.Settings(outputURL: tmp.appendingPathComponent("keyed.mp4"),
                                     outputWidth: size.w, outputHeight: size.h,
                                     downscale: downscale, presetPath: "",
                                     shaderEnabled: false, glitch: GlitchSettings(),
                                     codec: .h264, averageBitrate: 12_000_000)
        let brokenNow = broken
        try await Mp4Exporter(context: context).exportStill(
            source: source(), totalFrames: 6, fps: 12, paramValues: [:], settings: s,
            frameParams: { i, _ in (shader: nil, ntscJSON: nil, glitch: i >= 3 ? brokenNow : GlitchSettings()) },
            progress: { _ in })
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: s.outputURL))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let early = try await gen.image(at: CMTime(value: 1, timescale: 12)).image
        let late = try await gen.image(at: CMTime(value: 5, timescale: 12)).image
        XCTAssertGreaterThan(difference(early, late), 20, "the keyframed change reached the stage")
    }
}
