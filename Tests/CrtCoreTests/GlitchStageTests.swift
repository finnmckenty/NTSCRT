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

    func testGhostIsShiftedWithItsColourRotatedByTheDelay() throws {
        let input = texture { x, _ in (100..<116).contains(x) ? (0.8, 0.2, 0.2) : (0.5, 0.5, 0.5) }
        let delay = 3.0
        let px = try render(input, ["ghost_level": 0.5, "ghost_delay": delay])
        let shift = Int((delay / (NTSCTiming.activeLength / Double(W))).rounded())
        let y = A / 2
        let ghost = yiq(px, 108 + shift, y)
        let background = yiq(px, 180, y)
        let original = yiq(readback(input), 108, y)
        let gi = ghost.1 - background.1, gq = ghost.2 - background.2
        XCTAssertGreaterThan((gi * gi + gq * gq).squareRoot(), 0.03, "the ghost carries colour")
        let expected = atan2(original.2, original.1) - 2 * .pi * NTSCTiming.subcarrierMHz * delay
        var diff = (atan2(gq, gi) - expected).truncatingRemainder(dividingBy: 2 * .pi)
        if diff > .pi { diff -= 2 * .pi } else if diff < -.pi { diff += 2 * .pi }
        XCTAssertLessThan(abs(diff), 0.2, "hue rotated by 2π·fsc·τ (off by \(diff) rad)")
        // The ghost adds level × the bar's difference from its surroundings
        // (red on mid-grey is darker in luma: 0.38 vs 0.50).
        let barY = 0.299 * 0.8 + 0.587 * 0.2 + 0.114 * 0.2
        XCTAssertEqual(ghost.0 - background.0, 0.5 * (barY - 0.5), accuracy: 0.02,
                       "luma offset of half the bar's contrast")
    }

    func testColourKillerRemovesChromaWithoutBurst() throws {
        let input = texture { x, _ in (x / 20) % 2 == 0 ? (0.9, 0.2, 0.2) : (0.2, 0.3, 0.9) }
        var plan = healthyPlan()
        for i in plan.rows.indices { plan.rows[i].burstScale = 0 }
        let px = try render(input, plan: plan)
        func saturation(_ y: Int) -> Double {
            (0..<W).map { x in let c = yiq(px, x, y); return (c.1 * c.1 + c.2 * c.2).squareRoot() }
                .reduce(0, +) / Double(W)
        }
        XCTAssertGreaterThan(saturation(2), 0.1, "colour holds for a few lines...")
        XCTAssertLessThan(saturation(A - 1), 0.01, "...then the killer switches it off")
    }

    func testDropoutCompensationReplaysTheLineBefore() throws {
        let input = texture { x, y in (Float(y % 7) / 7, Float(x % 5) / 5, 0.5) }
        let raster = ReceiverRaster(width: W, activeLines: A)
        var plan = healthyPlan()
        plan.dropouts = [GlitchDropout(fieldLine: Int32(raster.vbiLines + 50), uStart: 20, uLength: 10)]
        let px = try render(input, plan: plan)
        let src = readback(input)
        let x = Int((25 - NTSCTiming.activeStart) / (NTSCTiming.activeLength / Double(W)))
        for c in 0..<3 {
            XCTAssertEqual(px[(50 * W + x) * 4 + c], src[(49 * W + x) * 4 + c], "replayed from line 49")
        }

        var off = plan
        off.settings = GlitchSettings(values: ["dropout_compensation": 0])
        let streak = try render(input, plan: off)
        XCTAssertGreaterThan(yiq(streak, x, 50).0, 0.95, "uncompensated: white streak")
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
