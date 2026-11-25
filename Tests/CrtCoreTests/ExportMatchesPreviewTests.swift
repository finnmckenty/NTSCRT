import XCTest
import Metal
import CrtAppBridge
@testable import CrtCore

/// An export is the picture the preview shows.
///
/// CRT shaders draw scanlines and masks in output pixels, so the size they
/// render at is part of the look. The preview rendered at 6× the picture and
/// up and scaled that to the window; exports rendered straight at the file's
/// size. A 640-wide picture was 6× on screen and 3× in a 1920 export; with
/// the Downscale off, 2× and 1× — where a mask shader's export showed only
/// the mask's stripes ("the blocks are too strong compared to the preview",
/// a user on 0.29.1) and the aperture shader was black (Finn, 2026-11-25:
/// a 1904 × 2544 still, Downscale off).
///
/// These run the real shaders: the preview's path (the chain at the plan's
/// size, then PreviewCompositor) against the export's (ExportFrame), into
/// the same number of pixels.
///
/// Needs the vendored librashader dylib and the slang-shaders submodule;
/// skipped (not failed) on a checkout that hasn't built them.
final class ExportMatchesPreviewTests: XCTestCase {

    private static var libraryLoaded = false
    private var context: MetalContext!
    private var shaders: URL!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dylib = root.appendingPathComponent("Vendor/librashader/librashader.dylib")
        shaders = root.appendingPathComponent("Vendor/slang-shaders/crt")
        guard FileManager.default.fileExists(atPath: dylib.path),
              FileManager.default.fileExists(atPath: shaders.appendingPathComponent("crt-aperture.slangp").path) else {
            throw XCTSkip("librashader.dylib / slang-shaders not built in this checkout")
        }
        if !Self.libraryLoaded {
            try LRShaderChain.loadLibrary(dylib.path)
            Self.libraryLoaded = true
        }
        context = try MetalContext()
    }

    // MARK: - helpers

    private var readable: MTLStorageMode { context.device.hasUnifiedMemory ? .shared : .managed }

    /// A picture with something for a shader to work on: soft shapes, a
    /// few hard edges, every brightness.
    private func picture(_ w: Int, _ h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = readable
        let t = context.device.makeTexture(descriptor: d)!
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let u = Double(x) / Double(w), v = Double(y) / Double(h)
                let wave = 0.5 + 0.35 * sin(u * 19) * cos(v * 13)
                let block = (Int(u * 8) + Int(v * 6)) % 3 == 0 ? 0.25 : 0.0
                let i = (y * w + x) * 4
                bytes[i] = UInt8(max(0, min(255, (wave * 0.8 + block) * 255)))
                bytes[i + 1] = UInt8(max(0, min(255, (0.2 + 0.6 * u) * 255)))
                bytes[i + 2] = UInt8(max(0, min(255, (wave + block * 0.5) * 255)))
            }
        }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        return t
    }

    private func target(_ w: Int, _ h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead, .shaderWrite]
        d.storageMode = readable
        return context.device.makeTexture(descriptor: d)!
    }

    private func bytes(of t: MTLTexture, after cb: MTLCommandBuffer) -> [UInt8] {
        if t.storageMode == .managed, let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: t)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: t.width * t.height * 4)
        t.getBytes(&out, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        return out
    }

    /// What the preview draws into a drawable of `size`: the chain at the
    /// plan's size, composited at zoom 1.
    private func preview(_ source: MTLTexture, downscale: DownscaleSpec?, chain: LRShaderChain,
                         size: (Int, Int), integerScale: Bool) throws -> (plan: PreviewScaling, pixels: [UInt8]) {
        let inW = downscale?.width ?? source.width, inH = downscale?.pictureHeight ?? source.height
        let plan = PreviewScaler.plan(inputWidth: inW, inputHeight: inH,
                                      drawableWidth: size.0, drawableHeight: size.1, integerScale: integerScale)
        let render = target(plan.renderWidth, plan.renderHeight)
        let dst = target(size.0, size.1)
        let cb = context.queue.makeCommandBuffer()!
        try Pipeline(context: context).encode(into: cb, chain: chain, inputTexture: source,
                                              outputTexture: render, downscale: downscale, frameCount: 1)
        let g = PreviewGeometry.make(plan: plan, drawableWidth: size.0, drawableHeight: size.1,
                                     integerScale: integerScale, zoom: 1, panX: 0, panY: 0)
        PreviewCompositor(context: context).composite(
            primary: render, secondary: render, into: dst, plan: plan, geometry: g,
            overlay: .init(compareEnabled: false, compareLineX: 0.5),
            background: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1), commandBuffer: cb)
        return (plan, bytes(of: dst, after: cb))
    }

    /// What an export of `size` holds (every route goes through ExportFrame).
    private func export(_ source: MTLTexture, downscale: DownscaleSpec?, chain: LRShaderChain,
                        size: (Int, Int)) throws -> [UInt8] {
        let dst = target(size.0, size.1)
        let cb = context.queue.makeCommandBuffer()!
        let input = ScanlineGrid.chainInputSize(width: source.width, height: source.height, downscale: downscale)
        try ExportFrame.encode(into: cb, pipeline: Pipeline(context: context), chain: chain,
                               bypass: ShaderBypass(context: context),
                               supersample: SupersampledPass.make(device: context.device, chainInput: input,
                                                                  target: (size.0, size.1)),
                               glitch: nil, inputTexture: source, outputTexture: dst,
                               downscale: downscale, frameCount: 1)
        return bytes(of: dst, after: cb)
    }

    private func chain(_ name: String) throws -> LRShaderChain {
        try LRShaderChain(presetPath: shaders.appendingPathComponent("\(name).slangp").path,
                          commandQueue: context.queue)
    }

    private func largestDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return 255 }
        var worst = 0
        for i in 0..<a.count { worst = max(worst, abs(Int(a[i]) - Int(b[i]))) }
        return worst
    }

    private func meanLuma(_ px: [UInt8]) -> Double {
        var sum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            sum += 0.114 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.299 * Double(px[i + 2])
        }
        return sum / Double(px.count / 4)
    }

    // MARK: - tests

    /// Shown and exported at the same number of pixels, the two are the
    /// same picture: with a mask shader and without, a small Downscale, a
    /// large one, and none.
    func testAnExportIsThePreviewsPicture() throws {
        let source = picture(960, 720)
        // (Downscale, export size, integer scale in the preview.) Sizes the
        // picture fits exactly, so the preview has no letterbox; with
        // integer scale, whole even multiples of the shader's picture.
        let cases: [(DownscaleSpec?, (Int, Int), Bool)] = [
            (DownscaleSpec(width: 256, height: 192, method: .area), (1920, 1440), false),
            (DownscaleSpec(width: 256, height: 192, method: .area), (1024, 768), true),
            (DownscaleSpec(width: 320, height: 240, method: .area), (1920, 1440), true),
            (DownscaleSpec(width: 640, height: 480, method: .area), (1920, 1440), false),
            (DownscaleSpec(width: 640, height: 480, method: .area), (1280, 960), true),
            (DownscaleSpec(width: 640, height: 480, method: .area), (800, 600), false),
            (nil, (1920, 1440), true),
            (nil, (1280, 960), false),
        ]
        for shader in ["crt-aperture", "crtglow_gauss"] {
            let chain = try chain(shader)
            for (downscale, size, integer) in cases {
                let name = "\(shader), downscale \(downscale.map { "\($0.width)" } ?? "off"), \(size.0)x\(size.1), integer \(integer)"
                let shown = try preview(source, downscale: downscale, chain: chain, size: size, integerScale: integer)
                XCTAssertEqual(shown.plan.displayWidth, size.0, "\(name): the test's size must be the preview's")
                XCTAssertEqual(shown.plan.displayHeight, size.1, "\(name): the test's size must be the preview's")
                let exported = try export(source, downscale: downscale, chain: chain, size: size)
                XCTAssertLessThanOrEqual(largestDifference(shown.pixels, exported), 1, name)
                XCTAssertGreaterThan(meanLuma(exported), 20, "\(name): a picture, not black")
            }
        }
    }

    /// A large still with the Downscale off: the shader is given at least
    /// two rows a line, so there is a picture — in the preview and in an
    /// export smaller than the still. (The aperture shader divides by the
    /// whole number of rows a line: black below one, and at one for 2544
    /// lines, whose reciprocal rounds down.)
    func testALargePictureWithTheDownscaleOffIsNotBlack() throws {
        let source = picture(1904, 2544)
        for shader in ["crt-aperture", "crtglow_gauss"] {
            let chain = try chain(shader)
            let shown = try preview(source, downscale: nil, chain: chain, size: (1436, 1920), integerScale: true)
            XCTAssertGreaterThanOrEqual(shown.plan.renderMultiple, 2)
            XCTAssertGreaterThan(meanLuma(shown.pixels), 40, "\(shader): the preview")
            for size in [(1436, 1920), (718, 960), (1904, 2544)] {
                let exported = try export(source, downscale: nil, chain: chain, size: size)
                XCTAssertGreaterThan(meanLuma(exported), 40, "\(shader): an export at \(size)")
            }
        }
    }
}
