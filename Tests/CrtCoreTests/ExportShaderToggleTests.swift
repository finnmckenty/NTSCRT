import XCTest
import Metal
import AVFoundation
import ImageIO
import CrtAppBridge
@testable import CrtCore

/// Every export route must follow the CRT toggle. None of them did: the
/// preview honoured it, but PNG, MP4/MOV (from a clip or a still) and GIF
/// (from either) all ran the shader regardless.
///
/// These drive the real exporters with the real shader on a flat grey
/// source, where the only thing that can put a row-to-row pattern in the
/// output is the shader's scanlines — so "on" must show them and "off" must
/// be flat, whatever the codec does to the pixels.
///
/// Needs the vendored librashader dylib and the slang-shaders submodule;
/// skipped (not failed) on a checkout that hasn't built them.
final class ExportShaderToggleTests: XCTestCase {

    private static var libraryLoaded = false
    private var context: MetalContext!
    private var presetPath = ""
    private var tmp: URL!

    private let sourceSize = (w: 640, h: 480)
    private let downscale = DownscaleSpec(width: 320, height: 240, method: .nearest)
    private let outputSize = (w: 960, h: 720)      // 3 rows per source line

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dylib = root.appendingPathComponent("Vendor/librashader/librashader.dylib")
        let preset = root.appendingPathComponent("Vendor/slang-shaders/crt/crtglow_gauss.slangp")
        guard FileManager.default.fileExists(atPath: dylib.path),
              FileManager.default.fileExists(atPath: preset.path) else {
            throw XCTSkip("librashader.dylib / slang-shaders not built in this checkout")
        }
        if !Self.libraryLoaded {
            try LRShaderChain.loadLibrary(dylib.path)
            Self.libraryLoaded = true
        }
        context = try MetalContext()
        presetPath = preset.path
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntscrt-toggle-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: - helpers

    private func flatGreySource() -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: sourceSize.w, height: sourceSize.h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = context.device.hasUnifiedMemory ? .shared : .managed
        let t = context.device.makeTexture(descriptor: d)!
        var bytes = [UInt8](repeating: 128, count: sourceSize.w * sourceSize.h * 4)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        t.replace(region: MTLRegionMake2D(0, 0, sourceSize.w, sourceSize.h), mipmapLevel: 0,
                  withBytes: bytes, bytesPerRow: sourceSize.w * 4)
        return t
    }

    private func mp4Settings(_ name: String, shader: Bool) -> Mp4Exporter.Settings {
        Mp4Exporter.Settings(outputURL: tmp.appendingPathComponent(name),
                             outputWidth: outputSize.w, outputHeight: outputSize.h,
                             downscale: downscale, presetPath: presetPath,
                             shaderEnabled: shader, glitch: nil, codec: .h264, averageBitrate: 8_000_000)
    }

    private func gifSettings(_ name: String, shader: Bool) -> GifExporter.Settings {
        GifExporter.Settings(outputURL: tmp.appendingPathComponent(name),
                             width: outputSize.w, height: outputSize.h, fps: 12,
                             downscale: downscale, presetPath: presetPath,
                             shaderEnabled: shader, glitch: nil)
    }

    private func firstFrame(of url: URL) async throws -> CGImage {
        if url.pathExtension == "mp4" {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            return try await gen.image(at: .zero).image
        }
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    /// Scanlines with the shader on, a flat field with it off.
    private func assertFollowsToggle(on: CGImage, off: CGImage, route: String) {
        let onMod = ImageStats.rowModulation(of: on)
        let offMod = ImageStats.rowModulation(of: off)
        XCTAssertGreaterThan(onMod, 8, "\(route): shader ON must draw scanlines (got \(onMod))")
        XCTAssertLessThan(offMod, 1.5, "\(route): shader OFF must not (got \(offMod))")
    }

    /// A short flat-grey clip to feed the video-source routes.
    private func makeSourceClip() async throws -> VideoSource {
        let settings = Mp4Exporter.Settings(
            outputURL: tmp.appendingPathComponent("source-clip.mp4"),
            outputWidth: sourceSize.w, outputHeight: sourceSize.h,
            downscale: nil, presetPath: presetPath,
            shaderEnabled: false, glitch: nil, codec: .h264, averageBitrate: 8_000_000)
        try await Mp4Exporter(context: context).exportStill(
            source: flatGreySource(), totalFrames: 6, fps: 12,
            paramValues: [:], settings: settings, progress: { _ in })
        return try await VideoSource(url: settings.outputURL, device: context.device)
    }

    // MARK: - one test per export route

    /// The PNG route's render step (AppState.exportPNG calls exactly this).
    func testSingleFrameRenderFollowsTheToggle() throws {
        func render(shader: Bool) throws -> CGImage {
            let pipeline = Pipeline(context: context)
            let chain: LRShaderChain? = shader
                ? try LRShaderChain(presetPath: presetPath, commandQueue: context.queue) : nil
            let target = try XCTUnwrap(makeRenderTarget(device: context.device,
                                                        width: outputSize.w, height: outputSize.h))
            let staging = try XCTUnwrap(makeStagingTexture(device: context.device,
                                                           width: outputSize.w, height: outputSize.h))
            let cb = try XCTUnwrap(context.queue.makeCommandBuffer())
            try ExportFrame.encode(into: cb, pipeline: pipeline, chain: chain,
                                   bypass: ShaderBypass(context: context), supersample: nil,
                                   glitch: nil,
                                   inputTexture: flatGreySource(), outputTexture: target,
                                   downscale: downscale, frameCount: 1)
            let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
            blit.copy(from: target, to: staging)
            if staging.storageMode == .managed { blit.synchronize(resource: staging) }
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            return try makeCGImage(from: staging)
        }
        assertFollowsToggle(on: try render(shader: true), off: try render(shader: false),
                            route: "single frame (PNG)")
    }

    func testVideoFromStillFollowsTheToggle() async throws {
        var frames: [Bool: CGImage] = [:]
        for shader in [true, false] {
            let settings = mp4Settings("still-\(shader).mp4", shader: shader)
            try await Mp4Exporter(context: context).exportStill(
                source: flatGreySource(), totalFrames: 4, fps: 12,
                paramValues: [:], settings: settings, progress: { _ in })
            frames[shader] = try await firstFrame(of: settings.outputURL)
        }
        assertFollowsToggle(on: frames[true]!, off: frames[false]!, route: "video from a still")
    }

    func testVideoFromClipFollowsTheToggle() async throws {
        let clip = try await makeSourceClip()
        var frames: [Bool: CGImage] = [:]
        for shader in [true, false] {
            let settings = mp4Settings("clip-\(shader).mp4", shader: shader)
            try await Mp4Exporter(context: context).export(
                source: clip, paramValues: [:], settings: settings, progress: { _ in })
            frames[shader] = try await firstFrame(of: settings.outputURL)
        }
        assertFollowsToggle(on: frames[true]!, off: frames[false]!, route: "video from a clip")
    }

    func testGifFromStillFollowsTheToggle() async throws {
        var frames: [Bool: CGImage] = [:]
        for shader in [true, false] {
            let settings = gifSettings("still-\(shader).gif", shader: shader)
            try await GifExporter(context: context).exportStill(
                source: flatGreySource(), totalFrames: 3,
                paramValues: [:], settings: settings, progress: { _ in })
            frames[shader] = try await firstFrame(of: settings.outputURL)
        }
        assertFollowsToggle(on: frames[true]!, off: frames[false]!, route: "GIF from a still")
    }

    func testGifFromClipFollowsTheToggle() async throws {
        let clip = try await makeSourceClip()
        var frames: [Bool: CGImage] = [:]
        for shader in [true, false] {
            let settings = gifSettings("clip-\(shader).gif", shader: shader)
            try await GifExporter(context: context).exportVideo(
                source: clip, paramValues: [:], settings: settings, progress: { _ in })
            frames[shader] = try await firstFrame(of: settings.outputURL)
        }
        assertFollowsToggle(on: frames[true]!, off: frames[false]!, route: "GIF from a clip")
    }
}
