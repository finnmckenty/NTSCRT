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

    /// Export viewport copies `visiblePicture`: every pixel in it shows the
    /// picture, the pixels just past each edge don't (or are off the
    /// drawable). Covers the letterboxed fit, zoom spilling into the bars,
    /// pan, and Fill.
    func testVisiblePictureIsExactlyThePixelsThatShowThePicture() {
        let cases: [(Bool, Float, (Float, Float))] = [
            (true, 1, (0, 0)), (true, 1.3, (0, 0)), (true, 2.41, (0.1, -0.2)),
            (true, 4, (0.3, 0.3)), (false, 1, (0, 0)), (false, 3, (-0.2, 0.1)),
        ]
        for (dw, dh) in drawables {
            for (integer, zoom, pan) in cases {
                let (_, g) = geometry(dw, dh, integer: integer, zoom: zoom, pan: pan)
                let label = "\(dw)x\(dh) integer=\(integer) zoom=\(zoom) pan=\(pan)"
                guard let r = g.visiblePicture else { return XCTFail(label) }
                let midX = r.x + r.width / 2, midY = r.y + r.height / 2
                for (px, py) in [(r.x, midY), (r.x + r.width - 1, midY), (midX, r.y),
                                 (midX, r.y + r.height - 1), (r.x, r.y),
                                 (r.x + r.width - 1, r.y + r.height - 1)] {
                    XCTAssertNotNil(g.uv(px: px, py: py), "inside \((px, py)) \(label)")
                }
                for (px, py) in [(r.x - 1, midY), (r.x + r.width, midY),
                                 (midX, r.y - 1), (midX, r.y + r.height)]
                    where (0..<dw).contains(px) && (0..<dh).contains(py) {
                    XCTAssertNil(g.uv(px: px, py: py), "outside \((px, py)) \(label)")
                }
            }
            // At zoom 1 it is the letterboxed frame, either way.
            for integer in [true, false] {
                let (_, fit) = geometry(dw, dh, integer: integer)
                XCTAssertEqual(fit.visiblePicture?.width, fit.targetWidth)
                XCTAssertEqual(fit.visiblePicture?.height, fit.targetHeight)
            }
        }
    }

    // MARK: - zoomed in, the picture fills the view

    /// A tall picture in a wide view (Finn's report: zoomed to 204%, it
    /// stayed in its own narrow frame with the sides of the view empty).
    /// Zoomed in, it grows past that frame until it fills the view.
    func testZoomedInThePictureSpillsPastItsFrameUntilItFillsTheView() {
        for integer in [true, false] {
            let (dw, dh) = (1600, 1000)
            let plan = PreviewScaler.plan(inputWidth: 240, inputHeight: 320,
                                          drawableWidth: dw, drawableHeight: dh,
                                          integerScale: integer)
            func shown(_ zoom: Float) -> (x: Int, y: Int, width: Int, height: Int)? {
                PreviewGeometry.make(plan: plan, drawableWidth: dw, drawableHeight: dh,
                                     integerScale: integer, zoom: zoom, panX: 0, panY: 0).visiblePicture
            }
            let label = "integer=\(integer)"
            let fit = shown(1)!
            XCTAssertEqual(fit.width, plan.displayWidth, label)
            XCTAssertLessThan(fit.width, dw / 2, "\(label): pillarboxed at zoom 1")
            // Halfway: wider than its frame, centered, not yet the view.
            let z = Float(dw) / Float(plan.displayWidth) / 2 + 0.5
            let mid = shown(z)!
            XCTAssertEqual(Float(mid.width), Float(plan.displayWidth) * z, accuracy: 2, label)
            XCTAssertEqual(mid.x + mid.width / 2, dw / 2, accuracy: 1, label)
            // Zoomed far enough: every pixel of the view shows picture.
            let full = shown(Float(dw) / Float(plan.displayWidth) + 0.01)!
            XCTAssertEqual(full.x, 0, label); XCTAssertEqual(full.width, dw, label)
            XCTAssertEqual(full.y, 0, label); XCTAssertEqual(full.height, dh, label)
        }
    }

    /// The pan stops where the picture's edge meets the view's edge, and
    /// doesn't move the picture along an axis where all of it is in sight.
    func testPanStopsAtThePicturesEdgeAndCentersWhatFits() {
        let (dw, dh) = (1600, 1000)
        let plan = PreviewScaler.plan(inputWidth: 240, inputHeight: 320,
                                      drawableWidth: dw, drawableHeight: dh, integerScale: false)
        // 1.5×: the picture's 1125 px fit the view's 1600 across; its height
        // overflows.
        let g = PreviewGeometry.make(plan: plan, drawableWidth: dw, drawableHeight: dh,
                                     integerScale: false, zoom: 1.5, panX: 0.4, panY: 0.4)
        XCTAssertEqual(g.panX, 0, "all of its width is in sight: stays centered")
        XCTAssertGreaterThan(g.panY, 0)
        XCTAssertEqual(g.uv(px: dw / 2, py: 0)!.y, 0, accuracy: 1e-3,
                       "panned all the way, its top edge is at the view's top")
        // Zoomed far in, the old limit (1 - 1/zoom) / 2 ignored the view
        // beyond the picture's frame and would show letterbox; this one
        // doesn't.
        let far = PreviewGeometry.make(plan: plan, drawableWidth: dw, drawableHeight: dh,
                                       integerScale: false, zoom: 6, panX: -1, panY: 0)
        XCTAssertNotNil(far.uv(px: dw - 1, py: dh / 2), "no letterbox at the right edge")
        XCTAssertEqual(far.uv(px: dw - 1, py: dh / 2)!.x, 1, accuracy: 1e-3)
        XCTAssertEqual(far.panX, -PreviewGeometry.panLimit(zoom: 6, viewExtent: Double(dw),
                                                           pictureExtent: Double(plan.displayWidth)))
    }
}
