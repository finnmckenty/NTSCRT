import XCTest
@testable import CrtCore

/// The composite mapping's invariants — one per preview bug that shipped.
final class PreviewGeometryTests: XCTestCase {

    private let input = (w: 320, h: 240)
    /// Even and odd letterbox deltas, square and not.
    private let drawables = [(1056, 1056), (1057, 1057), (1281, 961), (900, 700), (2048, 1536)]

    private func geometry(_ dw: Int, _ dh: Int, integer: Bool,
                          zoom: Float = 1, pan: (Float, Float) = (0, 0)) -> (PreviewScaling, PreviewGeometry) {
        let plan = PreviewScaler.plan(inputWidth: input.w, inputHeight: input.h,
                                      drawableWidth: dw, drawableHeight: dh,
                                      integerScale: integer)
        let g = PreviewGeometry.make(plan: plan, drawableWidth: dw, drawableHeight: dh,
                                     integerScale: integer, zoom: zoom,
                                     panX: pan.0, panY: pan.1)
        return (plan, g)
    }

    /// Horizontal uv span across the displayed rect (its first to last pixel).
    private func span(_ g: PreviewGeometry) -> Float {
        let left = g.uv(px: g.offsetX, py: g.drawableHeight / 2)!.x
        let right = g.uv(px: g.offsetX + g.targetWidth - 1, py: g.drawableHeight / 2)!.x
        return right - left
    }

    func testLetterboxOffsetIsWholePixelsAndCentered() {
        for (dw, dh) in drawables {
            let (plan, g) = geometry(dw, dh, integer: true)
            XCTAssertEqual(g.targetWidth, plan.displayWidth)
            XCTAssertEqual(g.targetHeight, plan.displayHeight)
            // Centered to within the one pixel an odd delta can't split.
            XCTAssertTrue((0...1).contains(dw - g.targetWidth - 2 * g.offsetX), "\(dw)")
            XCTAssertTrue((0...1).contains(dh - g.targetHeight - 2 * g.offsetY), "\(dh)")
        }
    }

    /// The banding bug: a half-pixel letterbox center made nearest sampling
    /// duplicate ~150 of 1280 rows. Every drawable row inside the display
    /// rect must map to its own texel row, in order.
    func testAtFitEachDisplayRowSamplesExactlyOneTexelRowInOrder() {
        for (dw, dh) in drawables {
            let (plan, g) = geometry(dw, dh, integer: true)
            let rows = plan.displayHeight
            for py in g.offsetY ..< g.offsetY + rows {
                XCTAssertEqual(g.texelRow(py: py, textureHeight: rows), py - g.offsetY,
                               "drawable \(dw)x\(dh), row \(py)")
            }
            if g.offsetY > 0 {
                XCTAssertNil(g.uv(px: dw / 2, py: g.offsetY - 1), "the row above the image is letterbox")
            }
        }
    }

    /// The zoom regressions: crossing into "sample the full render" must not
    /// move the framing, and zoom must scale the base framing of *each*
    /// mode by exactly 1/zoom — so toggling integer scale while zoomed
    /// changes nothing but the mode's own base size.
    func testZoomIsContinuousAndModeIndependent() {
        for (dw, dh) in drawables {
            for integer in [true, false] {
                let (_, base) = geometry(dw, dh, integer: integer, zoom: 1)
                let (_, justOver) = geometry(dw, dh, integer: integer, zoom: 1.002)
                XCTAssertFalse(base.samplesFullRender)
                XCTAssertTrue(justOver.samplesFullRender)
                let c0 = base.uv(px: dw / 2, py: dh / 2)!
                let c1 = justOver.uv(px: dw / 2, py: dh / 2)!
                XCTAssertEqual(c0.x, c1.x, accuracy: 2e-3)
                XCTAssertEqual(c0.y, c1.y, accuracy: 2e-3)
                for z: Float in [1.002, 2, 6, 9.72, 16] {
                    let (_, g) = geometry(dw, dh, integer: integer, zoom: z)
                    XCTAssertEqual(span(g) * z, span(base), accuracy: 1e-3,
                                   "integer=\(integer) zoom \(z) at \(dw)x\(dh)")
                }
            }
        }
    }

    func testSamplingModeFollowsZoomAndIntegerScale() {
        let (_, fitInt) = geometry(1056, 1056, integer: true)
        let (_, fitFill) = geometry(1056, 1056, integer: false)
        let (_, zoomed) = geometry(1056, 1056, integer: false, zoom: 6)
        XCTAssertTrue(fitInt.nearest, "integer scale is exact multiples: nearest")
        XCTAssertFalse(fitFill.nearest, "filling is a fractional resample: linear")
        XCTAssertTrue(zoomed.nearest && zoomed.samplesFullRender, "pixel inspection")
    }

    func testPanShiftsTheSampledRegion() {
        let (_, g) = geometry(1056, 1056, integer: true, zoom: 4, pan: (0.1, -0.05))
        let (_, g0) = geometry(1056, 1056, integer: true, zoom: 4)
        let a = g.uv(px: 528, py: 528)!, b = g0.uv(px: 528, py: 528)!
        XCTAssertEqual(a.x, b.x - 0.1, accuracy: 1e-6)
        XCTAssertEqual(a.y, b.y + 0.05, accuracy: 1e-6)
    }
}
