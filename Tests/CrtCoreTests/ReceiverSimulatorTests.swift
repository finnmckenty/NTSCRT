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
            XCTAssertTrue(p.dropouts.isEmpty)
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

    func testVerticalHoldNearCentreLocks() {
        for knob in [-0.12, 0.0, 0.12] {
            let tops = topLines(plans(["vertical_hold": knob], count: 30))
            XCTAssertEqual(Set(tops).count, 1, "knob \(knob) should hold still: \(tops)")
            XCTAssertLessThan(abs(tops[0] - raster.vbiLines), 8,
                              "locked picture sits near its normal framing (knob \(knob))")
        }
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

    func testHorizontalHoldCentredIsExact() {
        let p = plans(["horizontal_hold": 0.0])[0]
        XCTAssertTrue(p.rows.allSatisfy { $0.u0 == 0 })
    }

    func testHorizontalHoldSlidesThePictureBeforeItTears() {
        // Past the VCO's range the loop holds lock only by a standing phase
        // error: the whole picture shifts sideways, every row alike.
        let p = plans(["horizontal_hold": 0.42])[0]
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
        let slow = plans(["head_switch": 4, "afc_speed": 0], count: 6)
        // Fast AFC: caught up before the picture starts.
        let fast = plans(["head_switch": 4, "afc_speed": 1], count: 6)
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
        XCTAssertGreaterThan(weak, medium * 4)
    }

    func testHeadClogDropsFieldsAtAnyFrameRate() {
        // A strict every-other-field pattern would alias at 30 fps (frames
        // land on the same head forever); debris drops fields at random.
        for fps in [24.0, 30.0, 60.0] {
            let sim = ReceiverSimulator(raster: raster)
            let s = GlitchSettings(values: ["head_clog": 0.7])
            let losses = (0..<24).map { i -> Float in
                sim.advance(to: 1 + Double(i) / fps, settings: s)
                return sim.plan().rows[raster.activeLines / 2].burstScale
            }
            XCTAssertTrue(losses.contains { $0 < 0.3 }, "\(fps) fps: some fields lost \(losses)")
            XCTAssertTrue(losses.contains { $0 > 0.7 }, "\(fps) fps: others play \(losses)")
        }
    }

    // MARK: - determinism

    func testSameMomentAlwaysLooksTheSame() {
        let values: [String: Double] = ["vertical_hold": 0.5, "horizontal_hold": 0.7,
                                        "signal_strength": 0.3, "crinkle": 0.8,
                                        "head_switch": 3, "timebase_jitter": 1, "dropouts": 0.5]
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
        XCTAssertEqual(pa.dropouts, pb.dropouts)
        XCTAssertEqual(pa.ccBits, pc.ccBits)
    }
}
