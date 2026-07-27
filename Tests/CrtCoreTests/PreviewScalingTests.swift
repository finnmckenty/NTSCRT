import XCTest
@testable import CrtCore

/// Guards the preview's sizing rules. These broke once already: a change that
/// made the shader's look window-independent also made integer scale stop
/// snapping — the image scaled smoothly to fit instead of stepping between
/// whole multiples, and toggling it while zoomed shifted the magnification.
final class PreviewScalingTests: XCTestCase {

    // A 320x320 chain input (VGA width on a square source) in a range of
    // window sizes, plus a 320x240 4:3 case.
    private let inputs = [(320, 320), (320, 240), (256, 224)]
    private let drawables = [(632, 632), (900, 700), (1132, 1132), (1346, 1346),
                             (1532, 1532), (2000, 1400), (2560, 1600), (3000, 2200)]

    // MARK: - integer scale must snap

    func testDisplayIsAWholeMultipleOfTheInput() {
        for (iw, ih) in inputs {
            for (dw, dh) in drawables {
                let plan = PreviewScaler.plan(inputWidth: iw, inputHeight: ih,
                                              drawableWidth: dw, drawableHeight: dh,
                                              integerScale: true)
                guard plan.displayMultiple > 0 else { continue }   // too small to integer-scale
                XCTAssertEqual(plan.displayWidth, iw * plan.displayMultiple,
                               "display width must be a whole multiple of the input")
                XCTAssertEqual(plan.displayHeight, ih * plan.displayMultiple,
                               "display height must be a whole multiple of the input")
            }
        }
    }

    func testDisplayNeverOverflowsTheDrawable() {
        for (iw, ih) in inputs {
            for (dw, dh) in drawables {
                let plan = PreviewScaler.plan(inputWidth: iw, inputHeight: ih,
                                              drawableWidth: dw, drawableHeight: dh,
                                              integerScale: true)
                XCTAssertLessThanOrEqual(plan.displayWidth, dw)
                XCTAssertLessThanOrEqual(plan.displayHeight, dh)
            }
        }
    }

    /// The regression: as the window grows the displayed size must step, not
    /// track it continuously.
    func testDisplaySizeStepsRatherThanTrackingTheWindow() {
        var seen = Set<Int>()
        for dw in stride(from: 700, through: 2600, by: 7) {
            let plan = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                          drawableWidth: dw, drawableHeight: dw,
                                          integerScale: true)
            seen.insert(plan.displayWidth)
            XCTAssertEqual(plan.displayWidth % 320, 0,
                           "every displayed width must land on the 320px grid")
        }
        // ~270 window widths, but only a handful of distinct display sizes.
        XCTAssertLessThanOrEqual(seen.count, 8,
                                 "display size should take a few discrete values, got \(seen.sorted())")
    }

    /// Toggling integer scale at a window that isn't already a whole multiple
    /// must visibly change the displayed size — the "toggling does nothing"
    /// symptom.
    func testTogglingIntegerScaleChangesTheDisplayedSize() {
        let on = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                    drawableWidth: 1346, drawableHeight: 1346,
                                    integerScale: true)
        let off = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                     drawableWidth: 1346, drawableHeight: 1346,
                                     integerScale: false)
        XCTAssertEqual(off.displayWidth, 1346, "without integer scale the image fills the drawable")
        XCTAssertEqual(on.displayWidth, 1280, "with it, it snaps down to 4x")
        XCTAssertNotEqual(on.displayWidth, off.displayWidth)
    }

    // MARK: - the look must not depend on the window

    func testRenderMultipleMeetsTheScanlineFloorAtEveryWindowSize() {
        for (dw, dh) in drawables {
            let plan = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                          drawableWidth: dw, drawableHeight: dh,
                                          integerScale: true)
            XCTAssertGreaterThanOrEqual(
                plan.renderMultiple, PreviewScaler.minRenderMultiple,
                "at \(dw)x\(dh) the chain would render at x\(plan.renderMultiple) — below the floor the glow clips and scanlines vanish")
        }
    }

    /// The step from render to display has to be an exact integer factor, or
    /// the downsample resamples the scanline pattern and it shimmers.
    func testRenderIsAWholeMultipleOfDisplay() {
        for (iw, ih) in inputs {
            for (dw, dh) in drawables {
                let plan = PreviewScaler.plan(inputWidth: iw, inputHeight: ih,
                                              drawableWidth: dw, drawableHeight: dh,
                                              integerScale: true)
                guard plan.displayMultiple > 0 else { continue }
                XCTAssertEqual(plan.renderMultiple % plan.displayMultiple, 0,
                               "render x\(plan.renderMultiple) / display x\(plan.displayMultiple) is not a whole factor")
                XCTAssertEqual(plan.renderWidth % plan.displayWidth, 0)
                XCTAssertEqual(plan.renderHeight % plan.displayHeight, 0)
            }
        }
    }

    func testRenderStaysWithinTheTextureBudget() {
        for (iw, ih) in [(320, 320), (1024, 1024), (1920, 1080), (3840, 2160)] {
            for (dw, dh) in drawables {
                let plan = PreviewScaler.plan(inputWidth: iw, inputHeight: ih,
                                              drawableWidth: dw, drawableHeight: dh,
                                              integerScale: true, maxLongEdge: 4096)
                XCTAssertLessThanOrEqual(max(plan.renderWidth, plan.renderHeight), 4096,
                                         "input \(iw)x\(ih) at \(dw)x\(dh) blew the budget")
            }
        }
    }

    // MARK: - odd multiples, and windows too small to integer-scale

    func testDisplayMultiplePrefersEvenValues() {
        // A window that fits exactly 5x should step back to 4x: at odd
        // multiples the glow shaders' half-texel offset jitters line spacing.
        let plan = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                      drawableWidth: 320 * 5, drawableHeight: 320 * 5,
                                      integerScale: true)
        XCTAssertEqual(plan.displayMultiple, 4)
    }

    func testWindowTooSmallForOneCopyFallsBackToFitting() {
        let plan = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                      drawableWidth: 200, drawableHeight: 200,
                                      integerScale: true)
        XCTAssertEqual(plan.displayMultiple, 0, "can't integer-scale below 1x")
        XCTAssertLessThanOrEqual(plan.displayWidth, 200)
        XCTAssertGreaterThan(plan.displayWidth, 0)
        XCTAssertGreaterThanOrEqual(plan.renderMultiple, PreviewScaler.minRenderMultiple,
                                    "the shader still needs its rows even when the window is tiny")
    }

    // MARK: - integer scale off

    func testWithoutIntegerScaleTheImageFillsTheDrawable() {
        for (dw, dh) in drawables {
            let plan = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                          drawableWidth: dw, drawableHeight: dh,
                                          integerScale: false)
            XCTAssertEqual(plan.displayWidth, dw)
            XCTAssertEqual(plan.displayHeight, dh)
            XCTAssertFalse(plan.needsDownsample,
                           "filling the drawable shouldn't need a downsample pass")
        }
    }
}
