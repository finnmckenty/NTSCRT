import XCTest
import Metal
import CrtAppBridge
@testable import CrtCore

/// The NTSC stage runs in two places: playback runs it on its own thread
/// (PlaybackPipeline) and the main thread downscales the result; an export or
/// a paused frame goes through Pipeline.prepareChainInput. They must agree.
final class NtscChainTests: XCTestCase {
    private var context: MetalContext!
    private var pipeline: Pipeline!
    private var stage: NtscStage!

    override func setUpWithError() throws {
        let dylib = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/ntscrs-capi/ntscrs_capi.dylib")
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw XCTSkip("ntsc-rs isn't built (scripts/build-ntscrs.sh)")
        }
        if !NTSCFilter.isLibraryLoaded() { try NTSCFilter.loadLibrary(dylib.path) }
        context = try MetalContext()
        pipeline = Pipeline(context: context)
        stage = try XCTUnwrap(NtscStage())
        var settings = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(XCTUnwrap(stage.settingsJSON()).utf8)) as? [String: Any])
        settings["composite_noise"] = true
        settings["composite_noise_intensity"] = 0.5
        settings["scale_with_video_size"] = true
        try stage.setSettingsJSON(String(data: try JSONSerialization.data(withJSONObject: settings), encoding: .utf8)!)
    }

    private func pixels(_ out: MTLTexture) -> [UInt8] {
        let w = out.width, h = out.height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: out.pixelFormat, width: w, height: h, mipmapped: false)
        d.storageMode = context.device.hasUnifiedMemory ? .shared : .managed
        let staging = context.device.makeTexture(descriptor: d)!
        let cb = context.queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: out, to: staging)
        if staging.storageMode == .managed { blit.synchronize(resource: staging) }
        blit.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        staging.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return px
    }

    /// Same frame, same settings: the same chain input, byte for byte.
    func testPlaybackFramesAreTheChainInputsAnExportGets() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ntsc-chain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("ramp.mp4")
        let picture: MTLTexture = {
            let w = 640, h = 360
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead]; d.storageMode = .shared
            let t = context.device.makeTexture(descriptor: d)!
            var b = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let i = (y * w + x) * 4
                b[i] = UInt8(x * 255 / w); b[i + 1] = UInt8(y * 255 / h); b[i + 2] = UInt8((x + y) % 256)
            } }
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: b, bytesPerRow: w * 4)
            return t
        }()
        let settings = Mp4Exporter.Settings(outputURL: url, outputWidth: 640, outputHeight: 360,
                                            downscale: nil, presetPath: "", shaderEnabled: false,
                                            glitch: nil, digital: nil, codec: .h264, averageBitrate: 8_000_000)
        try await Mp4Exporter(context: context).exportStill(source: picture, totalFrames: 6, fps: 12,
                                                            paramValues: [:], settings: settings, progress: { _ in })
        let clip = try await VideoSource(url: url, device: context.device)
        let json = try XCTUnwrap(stage.settingsJSON())
        let config = PlaybackPipeline.Config(enabled: true, baseJSON: json, perFrameJSON: nil,
                                             generation: 0, digital: nil)
        let pipe = PlaybackPipeline(source: clip, device: context.device, startFrame: 0, config: config)
        pipe.start()
        defer { pipe.stop() }
        var out: PlaybackPipeline.Output?
        for _ in 0..<400 {
            if let o = pipe.takeOldest(generation: 0), o.frameIndex == 2 { out = o; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let frame = try XCTUnwrap(out, "frame 2 from playback")
        for spec in [DownscaleSpec(width: 320, height: 180, method: .area),
                     DownscaleSpec(width: 256, height: 144, method: .nearest)] {
            let cb = context.queue.makeCommandBuffer()!
            let played = try XCTUnwrap(pipeline.makeChainInputCopy(source: try XCTUnwrap(frame.processed),
                                                                   downscale: spec, commandBuffer: cb))
            cb.commit(); cb.waitUntilCompleted()
            let exported = try pipeline.prepareChainInput(source: frame.clean, downscale: spec, ntsc: stage,
                                                          frameCount: frame.frameIndex + 1)
            XCTAssertTrue(pixels(played) == pixels(exported), "\(spec.width)×\(spec.height): playback = export")
        }
    }
}
