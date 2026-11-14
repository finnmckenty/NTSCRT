import XCTest
@testable import CrtCore

/// The receiver model's physics, checked without a GPU: each test turns one
/// knob of the simulated set and asserts the failure a real set shows.
final class ReceiverSimulatorTests: XCTestCase {

    private let raster = ReceiverRaster(width: 320, activeLines: 240)
    private let H = NTSCTiming.line
    private let frame = 1.0 / 30

    /// A row's horizontal offset wrapped to (−½, ½] line: a scan starting
    /// just before a sync edge is reported ~63.5 µs into the previous line,
    /// the same position as −0.1 µs.
    private func offset(_ row: GlitchRow) -> Double {
        let u = Double(row.u0)
        return u > Double(row.lenCur) / 2 ? u - Double(row.lenCur) : u
    }

    private func settings(_ values: [String: Double]) -> GlitchSettings {
        GlitchSettings(values: values)
    }

    /// Plans for `count` consecutive 30 fps frames starting at `start`.
    private func plans(_ values: [String: Double], start: Double = 1.0,
                       count: Int = 1) -> [GlitchFieldPlan] {
        let sim = ReceiverSimulator(raster: raster)
        let s = settings(values)
        return (0..<count).map { i in
            sim.advance(to: start + Double(i) * frame, settings: s)
            return sim.plan()
        }
    }

    // MARK: - healthy

    func testHealthySetShowsThePictureExactly() {
        let sim = ReceiverSimulator(raster: raster)
        for t in [0.0, 0.5, 1.0, 2.37, 7.9] {
            sim.advance(to: t, settings: GlitchSettings())
            let p = sim.plan()
            XCTAssertEqual(p.rows.count, raster.activeLines)
            for (y, row) in p.rows.enumerated() {
                XCTAssertEqual(row.u0, 0, "t=\(t) row \(y)")
                XCTAssertEqual(Int(row.fieldLine), raster.vbiLines + y, "t=\(t) row \(y)")
                XCTAssertEqual(row.noiseIRE, 0)
                XCTAssertEqual(row.humIRE, 0)
                XCTAssertEqual(row.burstScale, 1)
            }
            XCTAssertEqual(p.chromaPhase, 0, accuracy: 1e-9)
            XCTAssertEqual(p.chromaGain, 1, accuracy: 1e-9)
            XCTAssertTrue(p.colorOn)
            XCTAssertEqual(p.pictureGain, 1)
            XCTAssertNil(p.vcr)
        }
    }

    func testIdentityHoldsAtOtherRasterSizes() {
        for (w, h) in [(256, 332), (320, 180), (640, 480), (1920, 1080)] {
            let r = ReceiverRaster(width: w, activeLines: h)
            let sim = ReceiverSimulator(raster: r)
            sim.advance(to: 1.3, settings: GlitchSettings())
            let p = sim.plan()
            XCTAssertTrue(p.rows.enumerated().allSatisfy {
                $0.element.u0 == 0 && Int($0.element.fieldLine) == r.vbiLines + $0.offset
            }, "\(w)x\(h)")
        }
    }

    // MARK: - vertical hold

    /// Field line shown at the top of the screen, unwrapped across frames.
    private func topLines(_ ps: [GlitchFieldPlan]) -> [Int] {
        let L = raster.totalLines
        var out: [Int] = []
        var unwrap = 0
        var prev: Int?
        for p in ps {
            let line = Int(p.rows[0].fieldLine)
            if let pv = prev {
                if line - pv > L / 2 { unwrap -= L } else if pv - line > L / 2 { unwrap += L }
            }
            out.append(line + unwrap)
            prev = line
        }
        return out
    }

    func testVerticalHoldNearCenterLocksAndSlides() {
        // In lock the phase-locked oscillator holds with a standing phase
        // error: the picture slides vertically as the hold is turned, then
        // starts to roll past ±~25%.
        var shifts: [Double: Int] = [:]
        for knob in [-0.15, -0.05, 0.0, 0.05, 0.15] {
            let tops = topLines(plans(["vertical_hold": knob], count: 30))
            XCTAssertEqual(Set(tops).count, 1, "knob \(knob) should hold still: \(tops)")
            var shift = tops[0] - raster.vbiLines
            let L = raster.totalLines
            if shift > L / 2 { shift -= L } else if shift < -L / 2 { shift += L }
            shifts[knob] = shift
        }
        XCTAssertEqual(shifts[0], 0, "centered: normal framing")
        XCTAssertGreaterThan(abs(shifts[0.05]!), 1, "the picture slides from the first few percent")
        XCTAssertGreaterThan(abs(shifts[0.15]!), abs(shifts[0.05]!), "further the more it's turned")
        XCTAssertTrue((shifts[0.15]! > 0) != (shifts[-0.15]! > 0), "opposite ways for opposite settings")
    }

    func testVerticalHoldRollsAboutEquallyBothWays() {
        func rate(_ knob: Double) -> Double {
            let t = topLines(plans(["vertical_hold": knob], count: 40))
            return Double(t.last! - t.first!) / 39
        }
        let up = rate(0.5), down = rate(-0.5)
        XCTAssertGreaterThan(abs(up), 3)
        XCTAssertEqual(abs(up), abs(down), accuracy: abs(up) * 0.35, "±50%: \(up) vs \(down) lines/field")
    }

    func testVerticalHoldPastLockRollsBothWays() {
        let up = topLines(plans(["vertical_hold": 0.6], count: 20))
        let down = topLines(plans(["vertical_hold": -0.6], count: 20))
        let dUp = up.last! - up.first!
        let dDown = down.last! - down.first!
        XCTAssertGreaterThan(abs(dUp), 30, "rolls when the oscillator is too slow: \(up)")
        XCTAssertGreaterThan(abs(dDown), 30, "rolls when the oscillator is too fast: \(down)")
        XCTAssertTrue((dUp > 0) != (dDown > 0), "opposite settings roll opposite ways (\(dUp), \(dDown))")
    }

    func testRollSpeedGrowsWithDetuning() {
        func speed(_ knob: Double) -> Double {
            let t = topLines(plans(["vertical_hold": knob], count: 30))
            return abs(Double(t.last! - t.first!))
        }
        XCTAssertLessThan(speed(0.35), speed(0.9))
    }

    // MARK: - horizontal hold

    func testHorizontalHoldCenteredIsExact() {
        let p = plans(["horizontal_hold": 0.0])[0]
        XCTAssertTrue(p.rows.allSatisfy { $0.u0 == 0 })
    }

    func testHorizontalHoldSlidesThePictureBeforeItTears() {
        // Past the VCO's range the loop holds lock only by a standing phase
        // error: the whole picture shifts sideways, every row alike.
        let p = plans(["horizontal_hold": 0.25])[0]
        let shifts = p.rows.map { offset($0) }
        let spread = shifts.max()! - shifts.min()!
        XCTAssertLessThan(spread, 0.5, "a sliding picture is still straight")
        let mean = shifts.reduce(0, +) / Double(shifts.count)
        XCTAssertGreaterThan(abs(mean), 1.0, "and visibly shifted (\(mean) µs)")
        XCTAssertLessThan(abs(mean), H / 4 + 1, "no further than the detector's range")
    }

    func testHorizontalHoldFarOutTears() {
        // Unlocked, the TV's lines drift through the signal's: the picture
        // breaks into strips, each a whole line further on.
        let p = plans(["horizontal_hold": 0.95])[0]
        var slips = 0
        for y in 1..<p.rows.count {
            let a = p.rows[y - 1], b = p.rows[y]
            let lineStep = Int(b.fieldLine) - Int(a.fieldLine)
            if lineStep != 1 && lineStep != 1 - raster.totalLines { slips += 1 }
        }
        XCTAssertGreaterThanOrEqual(slips, 3, "several tear bands per field")
        let spread = p.rows.map { Double($0.u0) }
        XCTAssertGreaterThan(spread.max()! - spread.min()!, H / 2, "rows offset by up to a line")
    }

    // MARK: - VCR timing

    func testHeadSwitchJumpBendsTheTopOfThePicture() {
        // Slow AFC: still chasing the head-switch jump at the top (flagging).
        let slow = plans(["vcr": 1, "head_switch": 4, "afc_speed": 0], count: 6)
        // Fast AFC: caught up before the picture starts.
        let fast = plans(["vcr": 1, "head_switch": 4, "afc_speed": 1], count: 6)
        func topBend(_ ps: [GlitchFieldPlan]) -> Double {
            ps.map { p -> Double in
                let base = offset(p.rows[raster.activeLines / 2])
                return abs(offset(p.rows[0]) - base)
            }.max()!
        }
        XCTAssertGreaterThan(topBend(slow), 1.0, "slow AFC flags at the top")
        XCTAssertLessThan(topBend(fast), topBend(slow) / 3, "fast AFC barely does")
        // The bend decays down the picture.
        let p = slow.max { abs(offset($0.rows[0])) < abs(offset($1.rows[0])) }!
        let mid = offset(p.rows[raster.activeLines / 2])
        XCTAssertGreaterThan(abs(offset(p.rows[0]) - mid), abs(offset(p.rows[40]) - mid))
    }

    // MARK: - reception

    func testWeakSignalBreaksHorizontalSync() {
        func ragged(_ strength: Double) -> Double {
            let p = plans(["signal_strength": strength], start: 1.5)[0]
            let u = p.rows.map { offset($0) }
            let mean = u.reduce(0, +) / Double(u.count)
            return (u.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(u.count)).squareRoot()
        }
        XCTAssertLessThan(ragged(0.45), 0.3, "moderate snow, sync holds")
        XCTAssertGreaterThan(ragged(0.06), 2.0, "very weak signal, sync breaks up")
    }

    func testSnowFollowsSignalStrength() {
        let strong = plans(["signal_strength": 1.0])[0].rows[0].noiseIRE
        let medium = plans(["signal_strength": 0.5])[0].rows[0].noiseIRE
        let weak = plans(["signal_strength": 0.2])[0].rows[0].noiseIRE
        XCTAssertEqual(strong, 0)
        XCTAssertGreaterThan(medium, 1)
        XCTAssertGreaterThan(weak, medium * 3)
        // And the knob's whole travel matters: some snow just below full.
        let nearlyFull = plans(["signal_strength": 0.9])[0].rows[0].noiseIRE
        XCTAssertGreaterThan(nearlyFull, 0.5, "snow starts just below 100%")
    }

    func testFullHumBreaksSyncInItsBarsButHalfDoesNot() {
        func ragged(_ hum: Double) -> Double {
            let p = plans(["hum": hum], start: 1.7)[0]
            let u = p.rows.map { offset($0) }
            return u.max()! - u.min()!
        }
        XCTAssertLessThan(ragged(0.5), 5, "half hum bends the picture gently")
        XCTAssertGreaterThan(ragged(1.0), 10, "full hum pulls the sync separator off: tearing in the bars")
    }

    func testHorizontalHoldActsFromTheFirstFewPercent() {
        let p = plans(["horizontal_hold": 0.08])[0]
        XCTAssertGreaterThan(abs(offset(p.rows[raster.activeLines / 2])), 0.5,
                             "a small turn already shifts the picture")
    }

    func testTheTwoHeadsCarryTheirOwnDirt() {
        // Dirty heads: each carries its own baked-on dirt, so fields played
        // by one head read through more spacing than the other's — and at
        // 60 fps both heads show.
        let sim = ReceiverSimulator(raster: raster)
        let s = GlitchSettings(values: ["vcr": 1, "head_dirt": 0.8, "head_mismatch": 0.5])
        var spacing: [UInt32: Float] = [:]
        for i in 0..<6 {
            sim.advance(to: 1 + Double(i) / 59.94, settings: s)
            let line = sim.plan().vcr!.lines[raster.activeLines / 2]
            spacing[line.head] = line.spacing
        }
        XCTAssertEqual(spacing.count, 2, "both heads play")
        XCTAssertGreaterThan(abs(spacing[0]! - spacing[1]!), 0.05, "with different dirt \(spacing)")
    }

    func testTapeFaultsNeedTheVCR() {
        // The deck and tape knobs do nothing until the VCR is playing.
        let off = plans(["tape_creases": 1, "head_dirt": 1, "head_switch": 4])[0]
        XCTAssertNil(off.vcr)
        XCTAssertTrue(off.rows.allSatisfy { $0.u0 == 0 && $0.burstScale == 1 })
    }

    // MARK: - determinism

    func testSameMomentAlwaysLooksTheSame() {
        let values: [String: Double] = ["vertical_hold": 0.5, "horizontal_hold": 0.7,
                                        "signal_strength": 0.3, "vcr": 1, "tape_creases": 0.8,
                                        "tape_mold": 0.6, "head_dirt": 0.4, "dirt_buildup": 0.8,
                                        "head_switch": 3, "timebase_jitter": 1, "tape_dropouts": 0.5]
        let s = GlitchSettings(values: values)
        // Frame by frame...
        let a = ReceiverSimulator(raster: raster)
        var t = 0.0
        while t < 1.3 - 1e-9 { t += frame; a.advance(to: min(t, 1.3), settings: s) }
        // ...equals a fresh re-simulation...
        let b = ReceiverSimulator(raster: raster)
        b.resimulate(to: 1.3, frameDuration: frame) { _ in s }
        // ...equals one long step.
        let c = ReceiverSimulator(raster: raster)
        c.advance(to: 1.3, settings: s)
        let pa = a.plan(), pb = b.plan(), pc = c.plan()
        XCTAssertEqual(pa.rows, pb.rows)
        XCTAssertEqual(pa.rows, pc.rows)
        XCTAssertEqual(pa.vcr?.lines, pb.vcr?.lines)
        XCTAssertEqual(pa.vcr?.lines, pc.vcr?.lines)
        XCTAssertEqual(pa.ccBits, pc.ccBits)
    }
}

extension ReceiverSimulatorTests {
    func testSearchShowsOneFewerNoiseBarThanTheSpeed() {
        let raster = ReceiverRaster(width: 320, activeLines: 240)
        for speed in [3.0, 5.0] {
            let sim = ReceiverSimulator(raster: raster)
            sim.advance(to: 1.0, settings: GlitchSettings(values: ["vcr": 1, "search_speed": speed]))
            let noisy = sim.plan().vcr!.lines.map { $0.gain < 0.5 }
            // Count noise bands down the screen (a band split by the top or
            // bottom edge counts once at each edge).
            var bands = 0
            for y in 1..<noisy.count where noisy[y] && !noisy[y - 1] { bands += 1 }
            if noisy[0] { bands += 1 }
            XCTAssertEqual(Double(bands), speed - 1, accuracy: 1, "\(speed)× search")
        }
        let normal = ReceiverSimulator(raster: raster)
        normal.advance(to: 1.0, settings: GlitchSettings(values: ["vcr": 1, "search_speed": 1]))
        XCTAssertTrue(normal.plan().vcr!.lines.allSatisfy { $0.gain == 1 }, "1× is normal play")
    }
}

extension ReceiverSimulatorTests {
    func testTrackingBandClimbsIntoThePictureAsTheErrorGrows() {
        let raster = ReceiverRaster(width: 320, activeLines: 240)
        func noisyRows(_ e: Double) -> [Int] {
            let sim = ReceiverSimulator(raster: raster)
            sim.advance(to: 1.0, settings: GlitchSettings(values: ["vcr": 1, "tracking": e]))
            return sim.plan().vcr!.lines.enumerated().filter { $0.element.gain < 0.5 }.map { $0.offset }
        }
        XCTAssertTrue(noisyRows(0).isEmpty, "tracked: nothing visible")
        let mild = noisyRows(0.3), bad = noisyRows(0.9)
        XCTAssertFalse(bad.isEmpty, "bad tracking shows a noise band")
        let mildCenter = mild.isEmpty ? Double(raster.activeLines) : Double(mild.reduce(0, +)) / Double(mild.count)
        let badCenter = Double(bad.reduce(0, +)) / Double(bad.count)
        XCTAssertLessThan(badCenter, mildCenter, "it climbs as the error grows")
        XCTAssertGreaterThan(bad.count, mild.count, "and widens")
    }
}
