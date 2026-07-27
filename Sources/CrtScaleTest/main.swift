import Foundation
import CrtCore

// Regression checks for the preview's sizing rules (PreviewScaler).
//
// These broke once: a change that made the shader's look independent of the
// window also made integer scale stop snapping — the image scaled smoothly to
// fit instead of stepping between whole multiples, and toggling it while
// zoomed shifted the magnification. Two requirements pull against each other
// here, so both directions are asserted.
//
// A plain executable rather than XCTest: this project builds with the Command
// Line Tools, which ship neither XCTest nor swift-testing. Run it directly, or
// let scripts/make-release.sh run it as a release gate.
//
//   swift build --product crt-scaletest && ./.build/debug/crt-scaletest

var failures = 0
var checks = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !condition {
        failures += 1
        let d = detail()
        FileHandle.standardError.write(Data("FAIL  \(label)\(d.isEmpty ? "" : "  — \(d)")\n".utf8))
    }
}

func equal<T: Equatable>(_ label: String, _ a: T, _ b: T) {
    check(label, a == b, "got \(a), expected \(b)")
}

let inputs = [(320, 320), (320, 240), (256, 224)]
let drawables = [(632, 632), (900, 700), (1132, 1132), (1346, 1346),
                 (1532, 1532), (2000, 1400), (2560, 1600), (3000, 2200)]

// MARK: - integer scale must snap

for (iw, ih) in inputs {
    for (dw, dh) in drawables {
        let plan = PreviewScaler.plan(inputWidth: iw, inputHeight: ih,
                                      drawableWidth: dw, drawableHeight: dh,
                                      integerScale: true)
        let at = "\(iw)x\(ih) in \(dw)x\(dh)"
        if plan.displayMultiple > 0 {
            equal("display width is a whole multiple [\(at)]",
                  plan.displayWidth, iw * plan.displayMultiple)
            equal("display height is a whole multiple [\(at)]",
                  plan.displayHeight, ih * plan.displayMultiple)
            // The step down to display size must be an exact integer factor,
            // or the downsample resamples the scanline pattern and shimmers.
            equal("render is a whole multiple of display [\(at)]",
                  plan.renderMultiple % plan.displayMultiple, 0)
            equal("render px is a whole multiple of display px [\(at)]",
                  plan.renderWidth % plan.displayWidth, 0)
        }
        check("display fits the drawable [\(at)]",
              plan.displayWidth <= dw && plan.displayHeight <= dh,
              "display \(plan.displayWidth)x\(plan.displayHeight)")
    }
}

// As the window grows the displayed size must STEP, not track it.
var distinctWidths = Set<Int>()
for dw in stride(from: 700, through: 2600, by: 7) {
    let plan = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                  drawableWidth: dw, drawableHeight: dw,
                                  integerScale: true)
    distinctWidths.insert(plan.displayWidth)
    equal("displayed width lands on the 320px grid [drawable \(dw)]",
          plan.displayWidth % 320, 0)
}
check("display size takes a few discrete values, not one per window size",
      distinctWidths.count <= 8, "got \(distinctWidths.sorted())")

// Toggling integer scale at a window that isn't already a whole multiple has
// to visibly change the size (the "toggling does nothing" symptom).
do {
    let on = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                drawableWidth: 1346, drawableHeight: 1346,
                                integerScale: true)
    let off = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                 drawableWidth: 1346, drawableHeight: 1346,
                                 integerScale: false)
    equal("integer scale off fills the drawable", off.displayWidth, 1346)
    equal("integer scale on snaps down to 4x", on.displayWidth, 1280)
    check("toggling integer scale changes the displayed size",
          on.displayWidth != off.displayWidth)
}

// MARK: - the look must not depend on the window

for (dw, dh) in drawables {
    let plan = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                  drawableWidth: dw, drawableHeight: dh,
                                  integerScale: true)
    check("render multiple meets the scanline floor [\(dw)x\(dh)]",
          plan.renderMultiple >= PreviewScaler.minRenderMultiple,
          "renders at x\(plan.renderMultiple); below the floor the glow clips and scanlines vanish")
}

for (iw, ih) in [(320, 320), (1024, 1024), (1920, 1080), (3840, 2160)] {
    for (dw, dh) in drawables {
        let plan = PreviewScaler.plan(inputWidth: iw, inputHeight: ih,
                                      drawableWidth: dw, drawableHeight: dh,
                                      integerScale: true, maxLongEdge: 4096)
        check("render stays within the texture budget [\(iw)x\(ih) in \(dw)x\(dh)]",
              max(plan.renderWidth, plan.renderHeight) <= 4096,
              "render \(plan.renderWidth)x\(plan.renderHeight)")
    }
}

// MARK: - edge cases

do {
    // A window fitting exactly 5x steps back to 4x: at odd multiples the glow
    // shaders' half-texel offset jitters line spacing by a row.
    let plan = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                  drawableWidth: 1600, drawableHeight: 1600,
                                  integerScale: true)
    equal("display multiple prefers even values", plan.displayMultiple, 4)
}

do {
    let plan = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                  drawableWidth: 200, drawableHeight: 200,
                                  integerScale: true)
    equal("a window below 1x can't integer-scale", plan.displayMultiple, 0)
    check("it falls back to fitting", plan.displayWidth <= 200 && plan.displayWidth > 0,
          "display \(plan.displayWidth)")
    check("the shader still gets its rows in a tiny window",
          plan.renderMultiple >= PreviewScaler.minRenderMultiple)
}

for (dw, dh) in drawables {
    let plan = PreviewScaler.plan(inputWidth: 320, inputHeight: 320,
                                  drawableWidth: dw, drawableHeight: dh,
                                  integerScale: false)
    equal("without integer scale the image fills the drawable [\(dw)x\(dh)]",
          plan.displayWidth, dw)
    check("filling the drawable needs no downsample pass [\(dw)x\(dh)]",
          !plan.needsDownsample)
}

// MARK: - result

if failures == 0 {
    print("crt-scaletest: \(checks) checks passed")
    exit(0)
} else {
    print("crt-scaletest: \(failures) of \(checks) checks FAILED")
    exit(1)
}
