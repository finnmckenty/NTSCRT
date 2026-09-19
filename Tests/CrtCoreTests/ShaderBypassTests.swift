import XCTest
import Metal
@testable import CrtCore

/// The "CRT off" renderer on its own: no shader library needed.
final class ShaderBypassTests: XCTestCase {

    private var context: MetalContext!

    override func setUpWithError() throws {
        context = try MetalContext()
    }

    private var readable: MTLStorageMode { context.device.hasUnifiedMemory ? .shared : .managed }

    /// BGRA texture from a closure giving each pixel's gray level.
    private func input(_ w: Int, _ h: Int, _ gray: (Int, Int) -> UInt8) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = readable
        let t = context.device.makeTexture(descriptor: d)!
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4, g = gray(x, y)
            bytes[i] = g; bytes[i + 1] = g; bytes[i + 2] = g
        } }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                  withBytes: bytes, bytesPerRow: w * 4)
        return t
    }

    /// Run the bypass into a `w`×`h` output and return its gray levels.
    private func render(_ source: MTLTexture, to w: Int, _ h: Int,
                        downscale: DownscaleSpec? = nil) throws -> [[Int]] {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead, .shaderWrite]
        d.storageMode = readable
        let out = context.device.makeTexture(descriptor: d)!
        let cb = context.queue.makeCommandBuffer()!
        try ShaderBypass(context: context).encode(into: cb, inputTexture: source,
                                                  outputTexture: out, downscale: downscale)
        if out.storageMode == .managed, let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: out)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        out.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return (0..<h).map { y in (0..<w).map { x in Int(bytes[(y * w + x) * 4 + 1]) } }
    }

    /// A whole-multiple output is a pure nearest-neighbour enlargement:
    /// every source pixel becomes a solid k×k block of its exact value.
    func testWholeMultipleIsExactNearestEnlargement() throws {
        let src = input(4, 3) { x, y in UInt8(20 + 17 * x + 50 * y) }
        let out = try render(src, to: 16, 12)
        for y in 0..<12 { for x in 0..<16 {
            XCTAssertEqual(out[y][x], 20 + 17 * (x / 4) + 50 * (y / 4), "pixel \(x),\(y)")
        } }
    }

    /// A fractional enlargement still gives every source pixel the same
    /// size (block centres keep their exact value) and conserves brightness,
    /// rather than making some columns a pixel wider than others.
    func testFractionalEnlargementKeepsBlockCentresAndBrightness() throws {
        let src = input(8, 6) { x, y in (x + y) % 2 == 0 ? 40 : 200 }
        let out = try render(src, to: 28, 21)        // 3.5×
        for sy in 0..<6 { for sx in 0..<8 {
            let cx = Int((Double(sx) + 0.5) * 3.5), cy = Int((Double(sy) + 0.5) * 3.5)
            XCTAssertEqual(out[cy][cx], (sx + sy) % 2 == 0 ? 40 : 200, accuracy: 2,
                           "centre of source pixel \(sx),\(sy)")
        } }
        let mean = Double(out.joined().reduce(0, +)) / Double(28 * 21)
        XCTAssertEqual(mean, 120, accuracy: 2, "box filter conserves brightness")
    }

    /// The downscale runs first: a 16×12 image downscaled to 4×3 and shown
    /// at 16×12 is made of solid 4×4 blocks.
    func testDownscaleIsAppliedBeforeEnlarging() throws {
        let src = input(16, 12) { x, y in UInt8((x * 13 + y * 29) % 251) }
        let out = try render(src, to: 16, 12,
                             downscale: DownscaleSpec(width: 4, height: 3, method: .nearest))
        for y in 0..<12 { for x in 0..<16 {
            XCTAssertEqual(out[y][x], out[(y / 4) * 4][(x / 4) * 4], "pixel \(x),\(y) within its block")
        } }
    }

    /// With the shader off nothing may draw scanlines: flat in, flat out.
    func testFlatInputStaysFlat() throws {
        let src = input(32, 24) { _, _ in 128 }
        for (w, h) in [(96, 72), (100, 75), (16, 12)] {
            let out = try render(src, to: w, h)
            XCTAssertTrue(out.joined().allSatisfy { abs($0 - 128) <= 1 }, "\(w)x\(h)")
        }
    }
}
