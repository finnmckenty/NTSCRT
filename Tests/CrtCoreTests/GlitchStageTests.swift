import XCTest
import Metal
@testable import CrtCore

/// The glitch stage's GPU passes, driven offscreen: what each simulated
/// failure actually puts on screen.
final class GlitchStageTests: XCTestCase {

    private var context: MetalContext!
    private let W = 320, A = 240

    override func setUpWithError() throws {
        context = try MetalContext()
    }

    private var readable: MTLStorageMode { context.device.hasUnifiedMemory ? .shared : .managed }

    private func texture(_ pixel: (Int, Int) -> (Float, Float, Float)) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W,
                                                         height: A, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = readable
        let t = context.device.makeTexture(descriptor: d)!
        var bytes = [UInt8](repeating: 255, count: W * A * 4)
        for y in 0..<A { for x in 0..<W {
            let (r, g, b) = pixel(x, y)
            let i = (y * W + x) * 4
            bytes[i] = UInt8(b * 255); bytes[i + 1] = UInt8(g * 255); bytes[i + 2] = UInt8(r * 255)
        } }
        t.replace(region: MTLRegionMake2D(0, 0, W, A), mipmapLevel: 0, withBytes: bytes, bytesPerRow: W * 4)
        return t
    }

    private func readback(_ tex: MTLTexture) -> [UInt8] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W,
                                                         height: A, mipmapped: false)
        d.storageMode = readable
        let staging = context.device.makeTexture(descriptor: d)!
        let cb = context.queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: tex, to: staging)
        if staging.storageMode == .managed { blit.synchronize(resource: staging) }
        blit.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: W * A * 4)
        staging.getBytes(&out, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, A), mipmapLevel: 0)
        return out
    }

    /// (Y, I, Q) of an output pixel, on the decoder's scale.
    private func yiq(_ px: [UInt8], _ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y * W + x) * 4
        let b = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, r = Double(px[i + 2]) / 255
        return (0.299 * r + 0.587 * g + 0.114 * b,
                0.596 * r - 0.274 * g - 0.322 * b,
                0.211 * r - 0.523 * g + 0.312 * b)
    }

    private func render(_ input: MTLTexture, time: Double = 1.0,
                        _ values: [String: Double] = [:]) throws -> [UInt8] {
        let renderer = try GlitchRenderer(context: context)
        let cb = context.queue.makeCommandBuffer()!
        let out = try renderer.encode(into: cb, chainInput: input, time: time,
                                      settings: GlitchSettings(values: values))
        cb.commit(); cb.waitUntilCompleted()
        return readback(out)
    }

    private func render(_ input: MTLTexture, plan: GlitchFieldPlan) throws -> [UInt8] {
        let renderer = try GlitchRenderer(context: context)
        let cb = context.queue.makeCommandBuffer()!
        let out = try renderer.render(into: cb, chainInput: input, plan: plan)
        cb.commit(); cb.waitUntilCompleted()
        return readback(out)
    }

    private func healthyPlan(_ values: [String: Double] = [:]) -> GlitchFieldPlan {
        let sim = ReceiverSimulator(raster: ReceiverRaster(width: W, activeLines: A))
        sim.advance(to: 1.0, settings: GlitchSettings(values: values))
        return sim.plan()
    }

    // MARK: -

    func testHealthySetReproducesItsInputExactly() throws {
        var rng = SystemRandomNumberGenerator()
        let seedTable = (0..<(W * A)).map { _ in Float(UInt8.random(in: 0...255, using: &rng)) / 255 }
        let input = texture { x, y in
            let v = seedTable[y * W + x]
            return (v, Float((x * 7 + y * 3) % 256) / 255, 1 - v)
        }
        for t in [0.0, 1.0, 3.3] {
            XCTAssertEqual(try render(input, time: t), readback(input), "t=\(t)")
        }
    }

    // MARK: - the picture as a composite signal (RF input)

    /// Color strength (0…) and luma at a pixel.
    private func color(_ px: [UInt8], _ x: Int, _ y: Int) -> Double {
        let (_, i, q) = yiq(px, x, y); return (i * i + q * q).squareRoot()
    }
    private func luma(_ px: [UInt8], _ x: Int, _ y: Int) -> Double { yiq(px, x, y).0 }
    /// Luma of every pixel of a row, and how much a list varies.
    private func row(_ px: [UInt8], _ y: Int) -> [Double] { (0..<W).map { yiq(px, $0, y).0 } }
    private func spread(_ v: [Double]) -> Double {
        let m = v.reduce(0, +) / Double(v.count)
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
    }

    /// With RF input off, its knobs do nothing: the picture is the input
    /// exactly.
    func testWithRFOffThePictureIsUntouched() throws {
        let input = texture { x, y in (Float(x % 17) / 17, Float(y % 11) / 11, 0.4) }
        XCTAssertEqual(try render(input, ["rf_crawl": 0.8, "rf_color": 3]), readback(input))
    }

    /// A flat color comes back from the signal as itself, and a flat gray
    /// with no color at all. (Averaged down the picture: the tuner's noise
    /// is in it.)
    func testAFlatColorSurvivesTheSignal() throws {
        for (r, g, b) in [(0.85, 0.2, 0.25), (0.2, 0.3, 0.8), (0.5, 0.5, 0.5)] as [(Float, Float, Float)] {
            let input = texture { _, _ in (r, g, b) }
            let cable = try render(input, time: 2.0)
            let rf = try render(input, time: 2.0, ["rf": 1])
            func mean(_ px: [UInt8], _ x: Int) -> (Double, Double, Double) {
                var s = (0.0, 0.0, 0.0)
                for y in 40..<200 { let v = yiq(px, x, y); s.0 += v.0; s.1 += v.1; s.2 += v.2 }
                return (s.0 / 160, s.1 / 160, s.2 / 160)
            }
            for x in [60, 160, 250] {
                let a = mean(cable, x), c = mean(rf, x)
                XCTAssertEqual(c.0, a.0, accuracy: 0.02); XCTAssertEqual(c.1, a.1, accuracy: 0.02)
                XCTAssertEqual(c.2, a.2, accuracy: 0.02)
            }
        }
    }

    /// White bars on black have no color; through the signal their edges
    /// do — fringes, which differ from line to line and change from field
    /// to field — while the middle of a wide bar and of the black between
    /// stay colorless. The picture's finest detail (a pixel on, a pixel
    /// off) is mostly gone. (The pattern repeats every three lines, so
    /// each measure is averaged over the lines of one phase, which leaves
    /// the tuner's noise out.)
    func testEdgesGetFringesThatDifferByLineAndCrawl() throws {
        // Bars 24 wide at x = 40…63, 120…143, 200…223; fine stripes on the
        // right.
        let input = texture { x, _ in
            let on = x >= 280 ? x % 2 == 0 : (x >= 40 && (x - 40) % 80 < 24)
            return on ? (1, 1, 1) : (0, 0, 0)
        }
        let cable = try render(input, time: 2.0)
        let a = try render(input, time: 2.0, ["rf": 1])
        let b = try render(input, time: 2.0 + 1 / NTSCTiming.fieldRate, ["rf": 1])
        /// (Y, I, Q) at x, over the lines y, y + 3, y + 6, …
        func at(_ px: [UInt8], _ x: Int, _ y: Int) -> (Double, Double, Double) {
            var s = (0.0, 0.0, 0.0), n = 0.0
            for r in stride(from: y, to: 220, by: 3) { let v = yiq(px, x, r); s.0 += v.0; s.1 += v.1; s.2 += v.2; n += 1 }
            return (s.0 / n, s.1 / n, s.2 / n)
        }
        func strength(_ v: (Double, Double, Double)) -> Double { (v.1 * v.1 + v.2 * v.2).squareRoot() }
        func fringe(_ px: [UInt8], _ y: Int) -> Double { (36..<44).map { strength(at(px, $0, y)) }.max()! }
        XCTAssertLessThan(fringe(cable, 100), 0.01)
        XCTAssertGreaterThan(fringe(a, 100), 0.06, "a colored fringe at the edge")
        XCTAssertLessThan(strength(at(a, 52, 100)), 0.02, "none in the middle of the bar")
        XCTAssertLessThan(strength(at(a, 90, 100)), 0.02, "none in the black between")
        // The fringe's color at one place: three lines running differ, and
        // the same line a field later differs.
        func apart(_ p: (Double, Double, Double), _ q: (Double, Double, Double)) -> Double {
            ((p.1 - q.1) * (p.1 - q.1) + (p.2 - q.2) * (p.2 - q.2)).squareRoot()
        }
        XCTAssertGreaterThan(apart(at(a, 40, 100), at(a, 40, 101)), 0.04, "line to line")
        XCTAssertGreaterThan(apart(at(a, 40, 101), at(a, 40, 102)), 0.04)
        XCTAssertGreaterThan(apart(at(a, 40, 100), at(b, 40, 100)), 0.04, "field to field: they crawl")
        XCTAssertLessThan(apart(at(a, 40, 100), at(a, 40, 103)), 0.02, "the pattern is three lines tall")
        // Fine stripes: full contrast on a cable, a fraction through the
        // set's brightness filter.
        func contrast(_ px: [UInt8]) -> Double { abs(at(px, 290, 100).0 - at(px, 291, 100).0) }
        XCTAssertGreaterThan(contrast(cable), 0.95)
        XCTAssertLessThan(contrast(a), 0.35)
        // A wide bar keeps its level.
        XCTAssertEqual(at(a, 52, 100).0, 1, accuracy: 0.03)

        // Edge crawl: stronger fringes, a harder edge (the bar's first
        // pixel overshoots). Color: no change to either.
        // (On gray bars: a white-on-black edge overshoots past what the
        // screen can show, and its fringe's color goes with it.)
        let gray = texture { x, _ in x >= 40 && (x - 40) % 80 < 24 ? (0.65, 0.65, 0.65) : (0.35, 0.35, 0.35) }
        let plain = try render(gray, time: 2.0, ["rf": 1])
        let crawl = try render(gray, time: 2.0, ["rf": 1, "rf_crawl": 1])
        XCTAssertGreaterThan(fringe(crawl, 100), 1.5 * fringe(plain, 100), "Edge crawl strengthens the fringes")
        XCTAssertLessThan(fringe(crawl, 100), 2.6 * fringe(plain, 100), "but not four times, as it once did")
        let peak = (40..<46).map { at(crawl, $0, 100).0 }.max()!
        XCTAssertGreaterThan(peak, 0.70, "and hardens the edge: a light line inside it")
        XCTAssertLessThan((40..<46).map { at(plain, $0, 100).0 }.max()!, 0.67)
        let vivid = try render(gray, time: 2.0, ["rf": 1, "rf_color": 3])
        XCTAssertEqual(fringe(vivid, 100), fringe(plain, 100), accuracy: 0.25 * fringe(plain, 100), "Color leaves the fringes")
    }

    /// Through the tuner there is grain even on a strong signal. A flat
    /// color follows the Color knob — none at 0, three times at 300% — and
    /// not Edge crawl, which makes the noise rougher instead.
    func testTheTunersNoiseAndTheTwoKnobs() throws {
        let gray = texture { _, _ in (0.5, 0.5, 0.5) }
        // (Clear of the picture's own edges, which are edges like any other.)
        func middle(_ px: [UInt8]) -> [Double] { Array(row(px, 120)[40..<280]) }
        let quiet = spread(middle(try render(gray, time: 2.0)))
        let grain = spread(middle(try render(gray, time: 2.0, ["rf": 1])))
        XCTAssertLessThan(quiet, 0.002, "nothing, directly")
        XCTAssertGreaterThan(grain, 0.004, "the tuner's noise")
        XCTAssertLessThan(grain, 0.03, "a trace, on a strong signal")
        let rough = try render(gray, time: 2.0, ["rf": 1, "rf_crawl": 0.8])
        // Colored noise: color where the gray has none.
        func speckle(_ px: [UInt8]) -> Double { (40..<280).map { color(px, $0, 120) }.reduce(0, +) / 240 }
        XCTAssertGreaterThan(speckle(rough), 1.4 * speckle(try render(gray, time: 2.0, ["rf": 1])), "rougher, more colored")
        XCTAssertGreaterThan(spread(middle(rough)), 1.5 * grain, "and grainier")

        let red = texture { _, _ in (0.6, 0.4, 0.4) }
        func strength(_ px: [UInt8]) -> Double {
            // The mean color, not the mean of strengths (the noise would add to those).
            var i = 0.0, q = 0.0, n = 0.0
            for y in stride(from: 40, to: 200, by: 3) { for x in stride(from: 40, to: 280, by: 5) {
                let v = yiq(px, x, y); i += v.1; q += v.2; n += 1
            } }
            return ((i / n) * (i / n) + (q / n) * (q / n)).squareRoot()
        }
        let asSent = strength(try render(red, time: 2.0, ["rf": 1]))
        XCTAssertEqual(strength(try render(red, time: 2.0, ["rf": 1, "rf_crawl": 0.8])), asSent, accuracy: 0.12 * asSent,
                       "Edge crawl leaves the picture's color")
        XCTAssertEqual(strength(try render(red, time: 2.0, ["rf": 1, "rf_color": 3])), 3 * asSent, accuracy: 0.3 * asSent,
                       "Color: three times")
        XCTAssertEqual(strength(try render(red, time: 2.0, ["rf": 1, "rf_color": 3, "rf_crawl": 0.8])), 3 * asSent,
                       accuracy: 0.35 * asSent, "whatever Edge crawl says")
        XCTAssertLessThan(strength(try render(red, time: 2.0, ["rf": 1, "rf_color": 0])), 0.08 * asSent, "black and white")
    }

    /// Where one color meets another of the same brightness there is no
    /// edge in brightness; through the tuner there are dots beside it —
    /// brightness, different on each of three lines running — which Edge
    /// crawl about doubles, and none out in the flat color either side.
    func testEdgeCrawlPutsDotsBesideAChangeOfColor() throws {
        // Two colors of equal luma (0.5): a red and a green.
        let input = texture { x, _ in x < 160 ? (0.80, 0.35, 0.50) : (0.25, 0.65, 0.40) }
        /// Luma at x over the lines y, y + 3, y + 6, … (one phase of the
        /// pattern; the tuner's noise averages out).
        func at(_ px: [UInt8], _ x: Int, _ y: Int) -> Double {
            var s = 0.0, n = 0.0
            for r in stride(from: y, to: 220, by: 3) { s += luma(px, x, r); n += 1 }
            return s / n
        }
        /// How far apart three lines running are, at their most, near x.
        func dots(_ px: [UInt8], _ xs: Range<Int>) -> Double {
            xs.map { x -> Double in
                let v = [at(px, x, 60), at(px, x, 61), at(px, x, 62)]
                return v.max()! - v.min()!
            }.max()!
        }
        let plain = try render(input, time: 2.0, ["rf": 1])
        let crawl = try render(input, time: 2.0, ["rf": 1, "rf_crawl": 1])
        XCTAssertGreaterThan(dots(plain, 156..<165), 0.08, "dots beside the edge")
        XCTAssertGreaterThan(dots(crawl, 156..<165), 1.7 * dots(plain, 156..<165), "more with Edge crawl")
        XCTAssertLessThan(dots(plain, 60..<100), 0.03, "none in the flat color")
        XCTAssertLessThan(dots(crawl, 60..<100), 0.03, "none in the flat color")
        XCTAssertLessThan(dots(crawl, 220..<260), 0.03)
    }

    /// Mean (Y, I, Q) at x down the picture: the three-line pattern and the
    /// tuner's noise average out.
    private func mean(_ px: [UInt8], _ x: Int) -> (y: Double, c: Double) {
        var s = (0.0, 0.0, 0.0)
        for r in 40..<202 { let v = yiq(px, x, r); s.0 += v.0; s.1 += v.1; s.2 += v.2 }
        return (s.0 / 162, ((s.1 / 162) * (s.1 / 162) + (s.2 / 162) * (s.2 / 162)).squareRoot())
    }

    /// Tuner smear: a colored bar's color trails past its right edge and is
    /// thin just inside its left one; its brightness stays where it was.
    func testTunerSmearTrailsTheColorToTheRight() throws {
        // A red bar at x = 100…139 on gray of the same brightness.
        let input = texture { x, _ in x >= 100 && x < 140 ? (0.80, 0.35, 0.50) : (0.5, 0.5, 0.5) }
        let plain = try render(input, time: 2.0, ["rf": 1])
        let smear = try render(input, time: 2.0, ["rf": 1, "rf_smear": 1])
        let full = mean(plain, 125).c
        XCTAssertGreaterThan(full, 0.1)
        XCTAssertLessThan(mean(plain, 148).c, 0.12 * full, "plain: no color 8 pixels past the bar")
        XCTAssertGreaterThan(mean(smear, 148).c, 0.22 * full, "smeared: it trails")
        XCTAssertGreaterThan(mean(plain, 103).c, 0.8 * full, "plain: all there 3 pixels in")
        XCTAssertLessThan(mean(smear, 103).c, 0.55 * full, "smeared: thin inside the left edge")
        XCTAssertLessThan(mean(smear, 80).c, 0.05 * full, "nothing ahead of the bar: it only trails")
        // Half way along the knob: between.
        let half = try render(input, time: 2.0, ["rf": 1, "rf_smear": 0.5])
        XCTAssertGreaterThan(mean(half, 103).c, mean(smear, 103).c + 0.1 * full)
        XCTAssertLessThan(mean(half, 103).c, mean(plain, 103).c - 0.1 * full)
        for x in [103, 125, 148] { XCTAssertEqual(mean(smear, x).y, mean(plain, x).y, accuracy: 0.02, "brightness at \(x)") }
    }

    /// Softness blurs the brightness's detail and leaves a flat color;
    /// Tuner offset lowers detail's contrast, weakens the color part way
    /// along and loses it (the set's color killer) at the end.
    func testSoftnessAndTunerOffset() throws {
        // Stripes two pixels wide (1.5 MHz at this width) over a flat red.
        let stripes = texture { x, _ in x % 4 < 2 ? (0.8, 0.8, 0.8) : (0.2, 0.2, 0.2) }
        let red = texture { _, _ in (0.6, 0.4, 0.4) }
        func contrast(_ v: [String: Double]) throws -> Double {
            let px = try render(stripes, time: 3.0, v)
            return abs(mean(px, 160).y + mean(px, 161).y - mean(px, 162).y - mean(px, 163).y) / 2
        }
        func color(_ v: [String: Double]) throws -> Double { mean(try render(red, time: 3.0, v), 160).c }
        func level(_ v: [String: Double]) throws -> Double { mean(try render(red, time: 3.0, v), 160).y }
        let c0 = try contrast(["rf": 1]), k0 = try color(["rf": 1]), y0 = try level(["rf": 1])
        XCTAssertGreaterThan(c0, 0.35)

        XCTAssertLessThan(try contrast(["rf": 1, "rf_soft": 0.5]), 0.75 * c0)
        XCTAssertLessThan(try contrast(["rf": 1, "rf_soft": 1]), 0.15 * c0, "the stripes merge")
        XCTAssertEqual(try color(["rf": 1, "rf_soft": 1]), k0, accuracy: 0.1 * k0, "Softness leaves the color")
        XCTAssertEqual(try level(["rf": 1, "rf_soft": 1]), y0, accuracy: 0.02)

        let hazy = try contrast(["rf": 1, "rf_offset": 1])
        XCTAssertLessThan(hazy, 0.6 * c0, "Tuner offset: lower contrast")
        XCTAssertGreaterThan(hazy, 0.2 * c0, "but the stripes are still there")
        XCTAssertEqual(try level(["rf": 1, "rf_offset": 1]), y0, accuracy: 0.02)
        let part = try color(["rf": 1, "rf_offset": 0.4])
        XCTAssertLessThan(part, 0.95 * k0, "weaker color part way")
        XCTAssertGreaterThan(part, 0.55 * k0, "the set's gain control making up for the burst")
        XCTAssertLessThan(try color(["rf": 1, "rf_offset": 1]), 0.1 * k0, "black and white at the end")
    }

    /// The ghost is in the signal: a copy of a white bar the delay later,
    /// at the ghost's level.
    func testTheGhostIsInTheCompositeSignal() throws {
        let input = texture { x, _ in x >= 100 && x < 124 ? (1, 1, 1) : (0, 0, 0) }
        let delay = 6.0                                    // µs: well clear of the bar
        let shift = Int((delay / (NTSCTiming.activeLength / Double(W))).rounded())
        let px = try render(input, time: 2.0, ["rf": 1, "ghost_level": 0.3, "ghost_delay": delay])
        let plainPx = try render(input, time: 2.0, ["rf": 1])
        func mean(_ p: [UInt8], _ x: Int) -> Double { (60..<180).map { luma(p, x, $0) }.reduce(0, +) / 120 }
        // (A ghost adds the signal's height above blanking, so black's
        // setup lifts the whole picture a little; the bar's ghost is what
        // stands above that.)
        let lift = mean(px, 112 + shift + 40) - mean(plainPx, 112 + shift + 40)
        XCTAssertEqual(lift, 0.3 * 7.5 / 92.5, accuracy: 0.01)
        XCTAssertEqual(mean(px, 112 + shift) - mean(plainPx, 112 + shift) - lift, 0.3, accuracy: 0.05)
    }

    func testRollingPictureShowsTheBlankingBar() throws {
        let input = texture { _, _ in (0.6, 0.6, 0.6) }
        let V = ReceiverRaster(width: W, activeLines: A).vbiLines
        var found = false
        for i in 0..<40 where !found {
            let px = try render(input, time: 1.0 + Double(i) / 30, ["vertical_hold": 0.6])
            let dark = (0..<A).map { y in yiq(px, W / 2, y).0 < 0.05 }
            // A contiguous dark band about the VBI's height, clear of the
            // screen edges.
            guard let first = dark.firstIndex(of: true), first > 0 else { continue }
            let run = dark[first...].prefix { $0 }.count
            if first + run < A {
                XCTAssertEqual(Double(run), Double(V), accuracy: 3, "bar height")
                found = true
            }
        }
        XCTAssertTrue(found, "the blanking bar crosses the screen while rolling")
    }

    func testTornPictureShowsDiagonalBlanking() throws {
        let input = texture { _, _ in (0.6, 0.6, 0.6) }
        let px = try render(input, time: 1.0, ["horizontal_hold": 0.95])
        var starts: [Int] = []
        for y in 0..<A {
            let dark = (0..<W).map { yiq(px, $0, y).0 < 0.05 }
            if let s = dark.firstIndex(of: true), dark[s...].prefix(while: { $0 }).count >= 20 {
                starts.append(s)
            }
        }
        XCTAssertGreaterThan(starts.count, A / 4, "the horizontal blanking runs through the picture")
        XCTAssertGreaterThan(starts.max()! - starts.min()!, W / 3, "and moves across it, row by row")
    }

    func testGhostIsShiftedWithItsColorRotatedByTheDelay() throws {
        let input = texture { x, _ in (100..<116).contains(x) ? (0.8, 0.2, 0.2) : (0.5, 0.5, 0.5) }
        let delay = 3.0
        let px = try render(input, ["ghost_level": 0.5, "ghost_delay": delay])
        let shift = Int((delay / (NTSCTiming.activeLength / Double(W))).rounded())
        let y = A / 2
        let ghost = yiq(px, 108 + shift, y)
        let background = yiq(px, 180, y)
        let original = yiq(readback(input), 108, y)
        let gi = ghost.1 - background.1, gq = ghost.2 - background.2
        XCTAssertGreaterThan((gi * gi + gq * gq).squareRoot(), 0.03, "the ghost carries color")
        let expected = atan2(original.2, original.1) - 2 * .pi * NTSCTiming.subcarrierMHz * delay
        var diff = (atan2(gq, gi) - expected).truncatingRemainder(dividingBy: 2 * .pi)
        if diff > .pi { diff -= 2 * .pi } else if diff < -.pi { diff += 2 * .pi }
        XCTAssertLessThan(abs(diff), 0.2, "hue rotated by 2π·fsc·τ (off by \(diff) rad)")
        // The ghost adds level × the bar's difference from its surroundings
        // (red on mid-gray is darker in luma: 0.38 vs 0.50).
        let barY = 0.299 * 0.8 + 0.587 * 0.2 + 0.114 * 0.2
        XCTAssertEqual(ghost.0 - background.0, 0.5 * (barY - 0.5), accuracy: 0.02,
                       "luma offset of half the bar's contrast")
    }

    func testSlidingPictureKeepsItsColorButATornOneDoesNot() throws {
        // The burst gate follows the incoming sync through a standing phase
        // error, so a picture that slides with the horizontal hold stays in
        // color; when the loop slips cycles, it can't.
        let input = texture { x, _ in (x / 20) % 2 == 0 ? (0.9, 0.2, 0.2) : (0.2, 0.3, 0.9) }
        func saturation(_ px: [UInt8]) -> Double {
            var total = 0.0
            for y in stride(from: 20, to: A - 20, by: 4) {
                for x in stride(from: 40, to: W - 40, by: 4) {
                    let c = yiq(px, x, y); total += (c.1 * c.1 + c.2 * c.2).squareRoot()
                }
            }
            return total
        }
        let reference = saturation(readback(input))
        let sliding = saturation(try render(input, ["horizontal_hold": 0.3]))
        XCTAssertGreaterThan(sliding, reference * 0.7, "a sliding picture keeps its color")
    }

    func testColorKillerRemovesChromaWithoutBurst() throws {
        let input = texture { x, _ in (x / 20) % 2 == 0 ? (0.9, 0.2, 0.2) : (0.2, 0.3, 0.9) }
        var plan = healthyPlan()
        for i in plan.rows.indices { plan.rows[i].burstScale = 0 }
        let px = try render(input, plan: plan)
        func saturation(_ y: Int) -> Double {
            (0..<W).map { x in let c = yiq(px, x, y); return (c.1 * c.1 + c.2 * c.2).squareRoot() }
                .reduce(0, +) / Double(W)
        }
        XCTAssertGreaterThan(saturation(2), 0.1, "color holds for a few lines...")
        XCTAssertLessThan(saturation(A - 1), 0.01, "...then the killer switches it off")
    }

    func testCaptionDataOnLine21() throws {
        let input = texture { _, _ in (0.6, 0.6, 0.6) }
        let raster = ReceiverRaster(width: W, activeLines: A)
        var plan = healthyPlan()
        plan.rows[10].fieldLine = Int32(raster.ccLine)
        plan.ccBits = 0b101_0101_0101_0101_0100
        let px = try render(input, plan: plan)
        let levels = (W / 3..<W).map { yiq(px, $0, 10).0 }
        XCTAssertGreaterThan(levels.max()!, 0.4, "data bits at 50 IRE")
        XCTAssertLessThan(levels.min()!, 0.05, "between blanking")
    }

    func testBrightnessRevealsBlankingBelowBlack() throws {
        let input = texture { _, _ in (0.6, 0.6, 0.6) }
        let raster = ReceiverRaster(width: W, activeLines: A)
        var plan = healthyPlan()
        plan.rows[20].fieldLine = Int32(raster.postEqEnd + 1)   // a blanking line
        let normal = try render(input, plan: plan)
        XCTAssertLessThan(yiq(normal, W / 2, 20).0, 0.02, "blanking is black normally")
        plan.settings = GlitchSettings(values: ["brightness": 1])
        let bright = try render(input, plan: plan)
        XCTAssertEqual(yiq(bright, W / 2, 20).0, 40.0 / 140.0, accuracy: 0.02,
                       "with brightness up, blanking (0 IRE) shows above the lowered cutoff")
    }
}

/// Seeking restores the nearest checkpoint instead of re-running from zero;
/// it must land on exactly the state a full re-run would.
final class GlitchCheckpointTests: XCTestCase {
    private var context: MetalContext!
    override func setUpWithError() throws { context = try MetalContext() }

    private func input() -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 320,
                                                         height: 240, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .private
        return context.device.makeTexture(descriptor: d)!
    }

    private func plan(_ r: GlitchRenderer, _ t: Double, _ s: GlitchSettings,
                      _ h: GlitchHistory? = nil) throws -> GlitchFieldPlan {
        let cb = context.queue.makeCommandBuffer()!
        _ = try r.encode(into: cb, chainInput: input(), time: t, settings: s, history: h)
        cb.commit(); cb.waitUntilCompleted()
        return r.lastPlan!
    }

    func testSeekingBackMatchesAFullRerunWithConstantSettings() throws {
        let s = GlitchSettings(values: ["vertical_hold": 0.5, "horizontal_hold": 0.65,
                                        "signal_strength": 0.3, "vcr": 1, "tape_creases": 0.7,
                                        "tape_mold": 0.5, "dirt_buildup": 0.9, "head_switch": 3])
        let seeker = try GlitchRenderer(context: context)
        _ = try plan(seeker, 9.0, s)                      // records checkpoints
        let viaCheckpoint = try plan(seeker, 4.37, s)     // jumps back
        let fresh = try plan(try GlitchRenderer(context: context), 4.37, s)
        XCTAssertEqual(viaCheckpoint.rows, fresh.rows)
        XCTAssertEqual(viaCheckpoint.vcr?.lines, fresh.vcr?.lines)
        XCTAssertEqual(viaCheckpoint.chromaPhase, fresh.chromaPhase)
    }

    func testSeekingBackMatchesAFullRerunWithKeyframedSettings() throws {
        let history = GlitchHistory(frameDuration: 1.0 / 24, id: 7) { t in
            GlitchSettings(values: ["vertical_hold": min(0.9, t / 6), "horizontal_hold": t > 3 ? 0.7 : 0])
        }
        let seeker = try GlitchRenderer(context: context)
        _ = try plan(seeker, 7.0, history.settingsAt(7.0), history)
        let t = 100.0 / 24                                 // a frame time
        let viaCheckpoint = try plan(seeker, t, history.settingsAt(t), history)
        let fresh = try plan(try GlitchRenderer(context: context), t, history.settingsAt(t), history)
        XCTAssertEqual(viaCheckpoint.rows, fresh.rows)
    }

    /// A short scrub forward through keyframed VCR knobs runs through the
    /// keyframes frame by frame, not on the destination's values throughout:
    /// a moment looks the same however the playhead reached it.
    func testScrubbingForwardMatchesAFullRerunWithKeyframedSettings() throws {
        let history = GlitchHistory(frameDuration: 1.0 / 24, id: 8) { t in
            GlitchSettings(values: ["vcr": 1, "tracking_offset": min(0.6, t / 5),
                                    "back_tension": t > 2.3 ? 0.6 : 0, "tape_sticky": min(1, t / 3),
                                    "dirt_buildup": 0.8, "tape_mold": 0.4])
        }
        let scrubber = try GlitchRenderer(context: context)
        _ = try plan(scrubber, 48.0 / 24, history.settingsAt(48.0 / 24), history)
        let t = 70.0 / 24                                  // under a second on
        let scrubbed = try plan(scrubber, t, history.settingsAt(t), history)
        let fresh = try plan(try GlitchRenderer(context: context), t, history.settingsAt(t), history)
        XCTAssertEqual(scrubbed.rows, fresh.rows)
        XCTAssertEqual(scrubbed.vcr?.lines, fresh.vcr?.lines)
    }

    /// Waits on the main run loop for a background re-run to land.
    private func settle(_ r: GlitchRenderer) {
        var settled = false
        r.onSettled = { settled = true }
        let deadline = Date().addingTimeInterval(30)
        while !settled && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(settled, "background re-run never landed")
    }

    /// A timing knob turned on a paused frame far into a clip: the preview
    /// shows something at once, and once the background re-run lands the
    /// frame is exactly what a full re-run on the main thread gives.
    func testBackgroundRerunAfterRetuneMatchesAFullRerun() throws {
        var values: [String: Double] = ["vcr": 1, "tracking_offset": 0.3, "back_tension": 0.2,
                                        "tape_sticky": 0.5, "dirt_buildup": 0.6, "tape_mold": 0.4]
        let preview = try GlitchRenderer(context: context)
        preview.rerunsInBackground = true
        _ = try plan(preview, 6.0, GlitchSettings(values: values))
        settle(preview)
        values["back_tension"] = 0.6                      // turned while paused
        let s = GlitchSettings(values: values)
        let meanwhile = try plan(preview, 6.0, s)
        XCTAssertFalse(meanwhile.rows.isEmpty)
        settle(preview)
        let settled = try plan(preview, 6.0, s)
        let fresh = try plan(try GlitchRenderer(context: context), 6.0, s)
        XCTAssertEqual(settled.rows, fresh.rows)
        XCTAssertEqual(settled.vcr?.lines, fresh.vcr?.lines)
        XCTAssertEqual(settled.chromaPhase, fresh.chromaPhase)
        // Its checkpoints are good for seeking back, too.
        let back = try plan(preview, 3.5, s)
        let freshBack = try plan(try GlitchRenderer(context: context), 3.5, s)
        XCTAssertEqual(back.rows, freshBack.rows)
    }

    private let worn = GlitchSettings(values: ["vcr": 1, "tracking_offset": 0.3, "back_tension": 0.2,
                                               "tape_sticky": 0.5, "dirt_buildup": 0.6, "tape_mold": 0.4,
                                               "signal_strength": 0.4])

    /// A looping clip comes back to its first frame every few seconds. The
    /// preview has the warmed-up set of time zero on hand, so the frame is
    /// exact at once: nothing to wait for. (Each loop used to re-run the
    /// warm-up in the background and hold the last frame's picture until it
    /// landed: the tape looked frozen for the clip's first second or two.)
    func testALoopBackToTheStartIsExactAtOnce() throws {
        let frame = 1.0 / 24
        let preview = try GlitchRenderer(context: context)
        preview.rerunsInBackground = true
        _ = try plan(preview, 0, worn)
        settle(preview)
        for k in 0...60 { _ = try plan(preview, Double(k) * frame, worn) }   // plays on
        let export = try GlitchRenderer(context: context)
        for k in 0...3 {                                                     // and loops
            let looped = try plan(preview, Double(k) * frame, worn)
            let exact = try plan(export, Double(k) * frame, worn)
            XCTAssertEqual(looped.rows, exact.rows, "frame \(k) after the loop")
            XCTAssertEqual(looped.vcr?.lines, exact.vcr?.lines, "frame \(k) after the loop")
        }
    }

    /// The same with keyframed knobs.
    func testALoopBackToTheStartIsExactAtOnceWithKeyframedSettings() throws {
        let frame = 1.0 / 24
        let history = GlitchHistory(frameDuration: frame, id: 11) { t in
            GlitchSettings(values: ["vcr": 1, "tracking_offset": min(0.6, t / 5),
                                    "tape_sticky": min(1, t / 3), "signal_strength": 0.4])
        }
        let preview = try GlitchRenderer(context: context)
        preview.rerunsInBackground = true
        _ = try plan(preview, 0, history.settingsAt(0), history)
        settle(preview)
        for k in 0...60 { _ = try plan(preview, Double(k) * frame, history.settingsAt(Double(k) * frame), history) }
        let export = try GlitchRenderer(context: context)
        for k in 0...3 {
            let t = Double(k) * frame
            let looped = try plan(preview, t, history.settingsAt(t), history)
            let exact = try plan(export, t, history.settingsAt(t), history)
            XCTAssertEqual(looped.rows, exact.rows, "frame \(k) after the loop")
            XCTAssertEqual(looped.vcr?.lines, exact.vcr?.lines, "frame \(k) after the loop")
            // And with that frame's knobs, not the last frame's before the loop.
            XCTAssertEqual(looped.vcr?.tape, exact.vcr?.tape, "frame \(k) after the loop")
            XCTAssertEqual(looped.vcr?.deck, exact.vcr?.deck, "frame \(k) after the loop")
        }
    }

    /// A finished background re-run is taken up by the next frame drawn,
    /// without waiting for the main queue (which a playing preview keeps
    /// busy). Nothing here lets the main queue run.
    func testAFinishedRerunIsTakenUpByTheNextFrame() throws {
        let preview = try GlitchRenderer(context: context)
        preview.rerunsInBackground = true
        let exact = try plan(try GlitchRenderer(context: context), 6.0, worn)
        var shown = try plan(preview, 6.0, worn)          // starts the re-run
        let deadline = Date().addingTimeInterval(30)
        while shown.rows != exact.rows, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            shown = try plan(preview, 6.0, worn)
        }
        XCTAssertEqual(shown.rows, exact.rows)
        XCTAssertEqual(shown.vcr?.lines, exact.vcr?.lines)
    }

    /// While a re-run is in flight a playing picture keeps moving: the state
    /// on hand runs on by as much as the playhead did.
    func testAPlayingPictureKeepsMovingWhileARerunIsInFlight() throws {
        let frame = 1.0 / 24
        let preview = try GlitchRenderer(context: context)
        preview.rerunsInBackground = true
        var last = try plan(preview, 40.0, worn)          // a long re-run starts
        for k in 1...4 {
            let next = try plan(preview, 40.0 + Double(k) * frame, worn)
            XCTAssertNotEqual(next.rows, last.rows, "frame \(k) stood still")
            last = next
        }
        // Paused, it holds still.
        let held = try plan(preview, 40.0 + 4 * frame, worn)
        if held.rows != last.rows {
            // (unless the re-run landed in between, which is exact)
            let exact = try plan(try GlitchRenderer(context: context), 40.0 + 4 * frame, worn)
            XCTAssertEqual(held.rows, exact.rows)
        }
    }

    func testBackgroundRerunAfterAJumpMatchesAFullRerunWithKeyframedSettings() throws {
        let history = GlitchHistory(frameDuration: 1.0 / 24, id: 9) { t in
            GlitchSettings(values: ["vcr": 1, "tracking_offset": min(0.6, t / 5),
                                    "back_tension": t > 2.3 ? 0.6 : 0, "tape_sticky": min(1, t / 3),
                                    "vertical_hold": min(0.9, t / 6)])
        }
        let preview = try GlitchRenderer(context: context)
        preview.rerunsInBackground = true
        let t = 130.0 / 24
        _ = try plan(preview, t, history.settingsAt(t), history)   // a far jump from nothing
        settle(preview)
        let settled = try plan(preview, t, history.settingsAt(t), history)
        let fresh = try plan(try GlitchRenderer(context: context), t, history.settingsAt(t), history)
        XCTAssertEqual(settled.rows, fresh.rows)
        XCTAssertEqual(settled.vcr?.lines, fresh.vcr?.lines)
    }
}
