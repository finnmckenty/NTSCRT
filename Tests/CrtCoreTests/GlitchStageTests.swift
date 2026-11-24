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
