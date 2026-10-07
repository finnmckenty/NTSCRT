import XCTest
import Metal
import ImageIO
import AVFoundation
@testable import CrtCore

/// Cropping the source to an aspect ratio before the chain: the rectangle,
/// and the crop landing on real pixels — a still on the GPU, both of a
/// clip's decode paths, the playback pipeline and the video exporters — on a
/// picture whose quadrants are four colors, so where a crop sits shows.
final class SourceCropTests: XCTestCase {

    private var context: MetalContext!
    private var tmp: URL!

    override func setUpWithError() throws {
        context = try MetalContext()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: the rectangle

    func testTheCropKeepsAllItCanAndCutsOneAxis() {
        // Landscape to portrait: the full height, a strip from the middle.
        let tall = SourceCrop(ratio: .init(9, 16)).rect(width: 1920, height: 1080)
        XCTAssertEqual(tall.height, 1080)
        XCTAssertEqual(tall.y, 0)
        XCTAssertEqual(tall.width, 608)          // 607.5, to the even number
        XCTAssertEqual(tall.x, (1920 - 608) / 2)
        // Portrait to landscape: the full width.
        let wide = SourceCrop(ratio: .init(16, 9)).rect(width: 1080, height: 1920)
        XCTAssertEqual(wide.width, 1080)
        XCTAssertEqual(wide.height, 608)
        XCTAssertEqual(wide.y, (1920 - 608) / 2)
        let square = SourceCrop(ratio: .square).rect(width: 640, height: 480)
        XCTAssertEqual(square.width, 480)
        XCTAssertEqual(square.height, 480)
        XCTAssertEqual(square.x, 80)
    }

    func testPositionSlidesTheCropAlongTheAxisItCuts() {
        XCTAssertEqual(SourceCrop(ratio: .square, position: 0).rect(width: 640, height: 480).x, 0)
        XCTAssertEqual(SourceCrop(ratio: .square, position: 1).rect(width: 640, height: 480).x, 160)
        let top = SourceCrop(ratio: .init(2, 1), position: 0).rect(width: 640, height: 480)
        let bottom = SourceCrop(ratio: .init(2, 1), position: 1).rect(width: 640, height: 480)
        XCTAssertEqual(top.height, 320)
        XCTAssertEqual(top.y, 0)
        XCTAssertEqual(bottom.y, 160)
        // Out of range is held inside the picture.
        XCTAssertEqual(SourceCrop(ratio: .square, position: 7).rect(width: 640, height: 480).x, 160)
        XCTAssertEqual(SourceCrop(ratio: .square, position: -1).rect(width: 640, height: 480).x, 0)
    }

    func testAPictureAlreadyThatShapeIsLeftWhole() {
        let c = SourceCrop(ratio: .init(16, 9))
        XCTAssertEqual(c.cut(width: 1920, height: 1080), .none)
        XCTAssertEqual(c.cut(width: 1918, height: 1080), .none, "within half a percent: no sliver cut")
        let r = c.rect(width: 1918, height: 1080)
        XCTAssertEqual(r.width, 1918)
        XCTAssertEqual(r.height, 1080)
        XCTAssertEqual(c.cut(width: 1440, height: 1080), .height)
        XCTAssertEqual(SourceCrop(ratio: .init(1, 2)).cut(width: 1080, height: 1080), .width)
    }

    func testZoomingInShrinksTheCropAndFreesBothWays() {
        // Twice in on a square crop of 640 × 360: half the largest crop (360²).
        let middle = SourceCrop(ratio: .square, scale: 2).rect(width: 640, height: 360)
        XCTAssertEqual(middle.width, 180)
        XCTAssertEqual(middle.height, 180)
        XCTAssertEqual(middle.x, (640 - 180) / 2)
        XCTAssertEqual(middle.y, (360 - 180) / 2)
        let corner = SourceCrop(ratio: .square, x: 1, y: 1, scale: 2).rect(width: 640, height: 360)
        XCTAssertEqual(corner.x, 460)
        XCTAssertEqual(corner.y, 180)
        // A picture's own shape crops once zoomed in (cutting black borders).
        let own = SourceCrop(ratio: .init(16, 9))
        XCTAssertFalse(own.crops(width: 640, height: 360))
        var zoomed = own
        zoomed.scale = 1.25
        XCTAssertTrue(zoomed.crops(width: 640, height: 360))
        XCTAssertEqual(zoomed.rect(width: 640, height: 360).width, 512)
        // Held to 1…maxScale.
        XCTAssertEqual(SourceCrop(ratio: .square, scale: 0.3).rect(width: 640, height: 360).width, 360)
        XCTAssertEqual(SourceCrop(ratio: .square, scale: 100).rect(width: 640, height: 360).width, 46)
    }

    func testAPixelRectangleMapsBackToTheCrop() {
        // `placed` undoes `rect`: the crop that keeps a rectangle the drag drew.
        let c = SourceCrop(ratio: .square)
        let placed = c.placed(x: 100, y: 60, width: 180, inWidth: 640, height: 360)
        XCTAssertEqual(placed.scale, 2, accuracy: 1e-9)
        let r = placed.rect(width: 640, height: 360)
        XCTAssertEqual(r.x, 100)
        XCTAssertEqual(r.y, 60)
        XCTAssertEqual(r.width, 180)
        // Pushed past the picture's edge, it stays inside.
        let past = c.placed(x: 600, y: -40, width: 180, inWidth: 640, height: 360).rect(width: 640, height: 360)
        XCTAssertEqual(past.x, 460)
        XCTAssertEqual(past.y, 0)
        // Wider than the largest crop: the largest crop.
        XCTAssertEqual(c.placed(x: 0, y: 0, width: 5000, inWidth: 640, height: 360).scale, 1)
    }

    func testRatioLabelsRoundTrip() {
        for r in [SourceCrop.Ratio.square] + SourceCrop.portrait + SourceCrop.landscape {
            XCTAssertEqual(SourceCrop.Ratio(label: r.label), r)
        }
        XCTAssertNil(SourceCrop.Ratio(label: "nope"))
        XCTAssertNil(SourceCrop.Ratio(label: "0:4"))
    }

    // MARK: pixels

    private enum Hue { case red, blue, green, yellow, other }

    /// Red top left, blue top right, green bottom left, yellow bottom right.
    private func quadrants(width: Int, height: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                         height: height, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = context.device.hasUnifiedMemory ? .shared : .managed
        let t = context.device.makeTexture(descriptor: d)!
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b): (UInt8, UInt8, UInt8)
                switch (x < width / 2, y < height / 2) {
                case (true, true): (r, g, b) = (230, 20, 20)
                case (false, true): (r, g, b) = (20, 20, 230)
                case (true, false): (r, g, b) = (20, 200, 20)
                case (false, false): (r, g, b) = (230, 220, 20)
                }
                let i = (y * width + x) * 4
                bytes[i] = b; bytes[i + 1] = g; bytes[i + 2] = r
            }
        }
        t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes,
                  bytesPerRow: width * 4)
        return t
    }

    private func hue(_ c: (Double, Double, Double)) -> Hue {
        let (r, g, b) = c
        if r > 0.6 && g > 0.6 && b < 0.35 { return .yellow }
        if r > 0.6 && g < 0.35 && b < 0.35 { return .red }
        if b > 0.6 && r < 0.35 && g < 0.35 { return .blue }
        if g > 0.5 && r < 0.35 && b < 0.35 { return .green }
        return .other
    }

    /// The color at (fx, fy), 0…1, of a texture (any storage).
    private func hue(of texture: MTLTexture, _ fx: Double, _ fy: Double) throws -> Hue {
        let staging = try XCTUnwrap(makeStagingTexture(device: context.device, width: texture.width,
                                                       height: texture.height))
        let cb = try XCTUnwrap(context.queue.makeCommandBuffer())
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: texture, to: staging)
        if staging.storageMode == .managed { blit.synchronize(resource: staging) }
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return try hue(of: makeCGImage(from: staging), fx, fy)
    }

    private func hue(of image: CGImage, _ fx: Double, _ fy: Double) throws -> Hue {
        var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
        px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let x = min(image.width - 1, Int(fx * Double(image.width)))
        let y = min(image.height - 1, Int(fy * Double(image.height)))
        let i = (y * image.width + x) * 4
        return hue((Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255))
    }

    func testAStillIsCroppedOnTheGPU() throws {
        let still = quadrants(width: 640, height: 360)
        // Square from the right: x 280…640 — blue over yellow, past a sliver of the left half.
        let right = try SourceCrop(ratio: .square, position: 1).apply(to: still, queue: context.queue)
        XCTAssertEqual(right.width, 360)
        XCTAssertEqual(right.height, 360)
        XCTAssertEqual(try hue(of: right, 0.6, 0.25), .blue)
        XCTAssertEqual(try hue(of: right, 0.6, 0.75), .yellow)
        XCTAssertEqual(try hue(of: right, 0.05, 0.25), .red)
        // A portrait picture cut to landscape at the top: red and blue only.
        let tall = quadrants(width: 360, height: 640)
        let top = try SourceCrop(ratio: .init(16, 9), position: 0).apply(to: tall, queue: context.queue)
        XCTAssertEqual(top.width, 360)
        XCTAssertEqual(top.height, 202)
        XCTAssertEqual(try hue(of: top, 0.25, 0.9), .red)
        XCTAssertEqual(try hue(of: top, 0.75, 0.9), .blue)
        // Already the shape: the same texture back.
        XCTAssertTrue(try SourceCrop(ratio: .init(16, 9)).apply(to: still, queue: context.queue) === still)
    }

    /// A short clip of the quadrants, 640 × 360.
    private func makeClip() async throws -> VideoSource {
        let url = tmp.appendingPathComponent("quadrants.mp4")
        let settings = Mp4Exporter.Settings(outputURL: url, outputWidth: 640, outputHeight: 360,
                                            downscale: nil, presetPath: "", shaderEnabled: false,
                                            glitch: nil, codec: .h264, averageBitrate: 8_000_000)
        try await Mp4Exporter(context: context).exportStill(source: quadrants(width: 640, height: 360),
                                                            totalFrames: 8, fps: 12, paramValues: [:],
                                                            settings: settings, progress: { _ in })
        return try await VideoSource(url: url, device: context.device)
    }

    func testAClipsFramesComeOutCroppedFromBothDecodePaths() async throws {
        let clip = try await makeClip()
        let crop = SourceCrop(ratio: .square, position: 1)
        // Sequential (playback and export).
        let reader = try clip.makeSequentialReader(crop: crop)
        let frame = try XCTUnwrap(reader.nextFrame())
        XCTAssertEqual(frame.texture.width, 360)
        XCTAssertEqual(frame.texture.height, 360)
        XCTAssertEqual(try hue(of: frame.texture, 0.6, 0.25), .blue)
        XCTAssertEqual(try hue(of: frame.texture, 0.6, 0.75), .yellow)
        let size = frame.withPixels { _, w, h, _ in (w, h) }
        XCTAssertEqual(size?.0, 360, "the CPU copy is the crop too")
        XCTAssertEqual(size?.1, 360)
        // Seeking (scrubbing).
        let seeked = try await clip.frame(atIndex: 3, crop: crop)
        XCTAssertEqual(seeked.width, 360)
        XCTAssertEqual(try hue(of: seeked, 0.6, 0.25), .blue)
        XCTAssertEqual(try hue(of: seeked, 0.6, 0.75), .yellow)
        // A vertical cut from the top, seeking: CGImage crops top row first
        // (bottom-up would hand back the bottom of the frame here).
        let top = try await clip.frame(atIndex: 3, crop: SourceCrop(ratio: .init(2, 1), position: 0))
        XCTAssertEqual(top.height, 320)
        XCTAssertEqual(try hue(of: top, 0.25, 0.2), .red)
        XCTAssertEqual(try hue(of: top, 0.75, 0.2), .blue)
        let sequentialTop = try XCTUnwrap(try clip.makeSequentialReader(
            crop: SourceCrop(ratio: .init(2, 1), position: 0)).nextFrame())
        XCTAssertEqual(try hue(of: sequentialTop.texture, 0.25, 0.2), .red)
        // Zoomed in on the clip's own shape: both paths crop it.
        let zoom = SourceCrop(ratio: .init(16, 9), x: 1, y: 1, scale: 2)
        let zoomedFrame = try XCTUnwrap(try clip.makeSequentialReader(crop: zoom).nextFrame())
        XCTAssertEqual(zoomedFrame.texture.width, 320)
        XCTAssertEqual(zoomedFrame.texture.height, 180)
        XCTAssertEqual(try hue(of: zoomedFrame.texture, 0.5, 0.5), .yellow)
        let zoomedSeek = try await clip.frame(atIndex: 3, crop: zoom)
        XCTAssertEqual(zoomedSeek.width, 320)
        XCTAssertEqual(try hue(of: zoomedSeek, 0.5, 0.5), .yellow)
        // No crop: the whole frame, as before.
        let whole = try XCTUnwrap(try clip.makeSequentialReader().nextFrame())
        XCTAssertEqual(whole.texture.width, 640)
        XCTAssertEqual(try hue(of: whole.texture, 0.75, 0.25), .blue)
    }

    func testThePlaybackPipelineHandsOutCroppedFrames() async throws {
        let clip = try await makeClip()
        let config = PlaybackPipeline.Config(enabled: false, baseJSON: nil, perFrameJSON: nil, generation: 0)
        let pipe = PlaybackPipeline(source: clip, device: context.device, startFrame: 0, config: config,
                                    crop: SourceCrop(ratio: .init(1, 2), position: 0))
        pipe.start()
        defer { pipe.stop() }
        var out: PlaybackPipeline.Output?
        for _ in 0..<200 where out == nil {
            out = pipe.takeOldest(generation: 0)
            if out == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let frame = try XCTUnwrap(out?.clean)
        XCTAssertEqual(frame.width, 180)
        XCTAssertEqual(frame.height, 360)
        XCTAssertEqual(try hue(of: frame, 0.5, 0.25), .red)
        XCTAssertEqual(try hue(of: frame, 0.5, 0.75), .green)
    }

    func testVideoExportsCropTheClip() async throws {
        let clip = try await makeClip()
        let crop = SourceCrop(ratio: .square, position: 0)
        // GIF: square from the left — red over green, where the uncropped
        // clip squeezed into a square would show blue and yellow at x 0.6.
        let gif = tmp.appendingPathComponent("cropped.gif")
        let gs = GifExporter.Settings(outputURL: gif, width: 120, height: 120, fps: 12, downscale: nil,
                                      presetPath: "", shaderEnabled: false, glitch: nil, crop: crop)
        try await GifExporter(context: context).exportVideo(source: clip, paramValues: [:], settings: gs,
                                                            progress: { _ in })
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(try hue(of: first, 0.6, 0.25), .red)
        XCTAssertEqual(try hue(of: first, 0.6, 0.75), .green)
        // MP4, the same.
        let mp4 = tmp.appendingPathComponent("cropped.mp4")
        let ms = Mp4Exporter.Settings(outputURL: mp4, outputWidth: 240, outputHeight: 240, downscale: nil,
                                      presetPath: "", shaderEnabled: false, glitch: nil,
                                      codec: .h264, averageBitrate: 8_000_000, crop: crop)
        try await Mp4Exporter(context: context).export(source: clip, paramValues: [:], settings: ms,
                                                       progress: { _ in })
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mp4))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: 1, timescale: 12)).image
        XCTAssertEqual(try hue(of: image, 0.6, 0.25), .red)
        XCTAssertEqual(try hue(of: image, 0.6, 0.75), .green)
    }
}
