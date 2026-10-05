import XCTest
import Metal
@testable import CrtCore

/// Drives the real composite shader offscreen with a synthetic scanline
/// render, and reads the result back — the GUI-free version of the checks
/// that used to need a window and a screenshot.
final class PreviewCompositorTests: XCTestCase {

    private var context: MetalContext!
    private let input = (w: 320, h: 240)

    override func setUpWithError() throws {
        context = try MetalContext()
    }

    private var readableStorage: MTLStorageMode {
        context.device.hasUnifiedMemory ? .shared : .managed
    }

    /// A "render" at `multiple`× the input: each source line is `multiple`
    /// rows, the first `bright` of them white, the rest black.
    private func scanlineRender(multiple: Int, bright: Int) -> MTLTexture {
        let w = input.w * multiple, h = input.h * multiple
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = readableStorage
        let t = context.device.makeTexture(descriptor: d)!
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h where y % multiple < bright {
            for x in 0..<w {
                let i = (y * w + x) * 4
                bytes[i] = 255; bytes[i + 1] = 255; bytes[i + 2] = 255; bytes[i + 3] = 255
            }
        }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                  withBytes: bytes, bytesPerRow: w * 4)
        return t
    }

    private func composite(render: MTLTexture, drawable: (Int, Int),
                           integer: Bool, zoom: Float) -> (PreviewGeometry, [Float]) {
        let (dw, dh) = drawable
        let plan = PreviewScaler.plan(inputWidth: input.w, inputHeight: input.h,
                                      drawableWidth: dw, drawableHeight: dh,
                                      integerScale: integer)
        XCTAssertEqual(plan.renderWidth, render.width, "test render must match the plan")
        let g = PreviewGeometry.make(plan: plan, drawableWidth: dw, drawableHeight: dh,
                                     integerScale: integer, zoom: zoom, panX: 0, panY: 0)
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: dw, height: dh, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = readableStorage
        let dst = context.device.makeTexture(descriptor: d)!

        let compositor = PreviewCompositor(context: context)
        let cb = context.queue.makeCommandBuffer()!
        compositor.composite(primary: render, secondary: render, into: dst,
                             plan: plan, geometry: g,
                             overlay: .init(compareEnabled: false, compareLineX: 0.5),
                             background: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
                             commandBuffer: cb)
        if dst.storageMode == .managed, let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: dst)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()

        // Luminance down the center column.
        var bytes = [UInt8](repeating: 0, count: dw * dh * 4)
        dst.getBytes(&bytes, bytesPerRow: dw * 4, from: MTLRegionMake2D(0, 0, dw, dh), mipmapLevel: 0)
        let x = dw / 2
        let column = (0..<dh).map { y -> Float in
            let i = (y * dw + x) * 4
            return (0.2126 * Float(bytes[i + 2]) + 0.7152 * Float(bytes[i + 1]) + 0.0722 * Float(bytes[i])) / 255
        }
        return (g, column)
    }

    /// Integer scale at fit, odd letterbox delta: the 6× render (3 bright
    /// rows of 6) box-filters to a 2× display whose rows must alternate
    /// bright/dark exactly — any duplicated or dropped row breaks the
    /// alternation. This is the "~150 duplicated rows" banding bug, checked
    /// on the real shader.
    func testFitAtOddLetterboxAlternatesEveryRow() {
        let render = scanlineRender(multiple: 6, bright: 3)
        let (g, column) = composite(render: render, drawable: (1057, 1057), integer: true, zoom: 1)
        XCTAssertFalse(g.samplesFullRender)
        XCTAssertEqual(g.targetHeight, 480, "1057 px shows a 320x240 input at 2x")
        var violations = 0
        for py in g.offsetY ..< g.offsetY + g.targetHeight - 1 {
            let a = column[py], b = column[py + 1]
            if abs(a - b) < 0.5 { violations += 1 }     // rows must alternate 1,0,1,0
        }
        XCTAssertEqual(violations, 0, "rows duplicated/dropped at fit")
        // The shader paints out-of-bounds as (0.05, 0.05, 0.06): near-black.
        XCTAssertLessThan(column[g.offsetY - 1], 0.1, "letterbox above the image")
    }

    /// Zoomed in, the composite must sample the full render: the 6-row
    /// scanline pattern shows at full contrast with runs of 12 drawable
    /// pixels (6 render rows × 2 px each at 6× zoom on a 2× display). The
    /// display fit — the regression — would show a 2-row pattern instead.
    func testZoomedCompositeShowsTheRenderScanlines() {
        let render = scanlineRender(multiple: 6, bright: 3)
        let (g, column) = composite(render: render, drawable: (1056, 1056), integer: true, zoom: 6)
        XCTAssertTrue(g.samplesFullRender)
        let mid = column[(1056 / 2 - 60) ..< (1056 / 2 + 60)]
        XCTAssertGreaterThan(mid.max()! - mid.min()!, 0.95, "full contrast scanlines")
        // Run lengths of equal luminance: bright 3 texels, dark 3 texels,
        // each texel 2 px → 6-px runs.
        var runs: [Int] = []
        var run = 1
        for i in mid.indices.dropFirst() {
            if abs(mid[i] - mid[i - 1]) < 0.05 { run += 1 } else { runs.append(run); run = 1 }
        }
        let interior = runs.dropFirst()
        XCTAssertFalse(interior.isEmpty)
        for r in interior { XCTAssertTrue((5...7).contains(r), "run \(r) px, expected 6") }
    }

    /// Fill mode (integer scale off) is still rendered at the scanline floor
    /// and box-filtered to the drawable — the fit samples a drawable-sized
    /// texture, and the scanlines survive as modulation.
    func testFillModeFitsTheFloorRenderToTheDrawable() {
        let plan = PreviewScaler.plan(inputWidth: input.w, inputHeight: input.h,
                                      drawableWidth: 700, drawableHeight: 525, integerScale: false)
        XCTAssertEqual(plan.renderMultiple, 6)
        let render = scanlineRender(multiple: plan.renderMultiple, bright: 3)
        let (g, column) = composite(render: render, drawable: (700, 525), integer: false, zoom: 1)
        XCTAssertEqual(g.targetHeight, 525, "fills the drawable")
        let mid = column[200..<300]
        XCTAssertGreaterThan(mid.max()! - mid.min()!, 0.25, "scanline modulation reaches the screen")
        let mean = column.reduce(0, +) / Float(column.count)
        XCTAssertEqual(mean, 0.5, accuracy: 0.03, "box filter conserves brightness (3 of 6 rows bright)")
    }
}
