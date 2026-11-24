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
                                        "head_switch": 3, "transport_flutter": 0.5, "tape_dropouts": 0.5,
                                        "tape_sticky": 0.6, "back_tension": 0.4, "tracking_offset": 0.3,
                                        "tape_edge_damage": 0.7, "tape_generation": 2, "tape_speed": 2]
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

/// How much of its own tracks' FM a planned line's head reads at its start
/// (1: centered on its own track, in SP).
private func ownShare(_ line: VcrLine, _ format: TapeFormat = .sp) -> Double {
    let r = format.read(delta: Double(line.delta0))
    return (0..<3).filter { (r.center - 1 + $0) % 2 == 0 }.map { r.fm[$0] }.reduce(0, +)
}

extension ReceiverSimulatorTests {
    func testSearchCrossesTracksIntoNoiseBars() {
        // At n× the tape runs n× as fast, so a head's sweep crosses n−1
        // tracks: picture on its own azimuth's, noise on the others' —
        // (n−1)/2 noise bars a field.
        let raster = ReceiverRaster(width: 320, activeLines: 240)
        for speed in [3.0, 5.0, 9.0] {
            let sim = ReceiverSimulator(raster: raster)
            sim.advance(to: 1.0, settings: GlitchSettings(values: ["vcr": 1, "search_speed": speed]))
            let noisy = sim.plan().vcr!.lines.map { ownShare($0) < 0.3 }
            var bands = 0
            for y in 1..<noisy.count where noisy[y] && !noisy[y - 1] { bands += 1 }
            if noisy[0] { bands += 1 }
            XCTAssertEqual(Double(bands), (speed - 1) / 2, accuracy: 1, "\(speed)× search")
            XCTAssertTrue(noisy.contains(false), "picture between the bars at \(speed)×")
        }
        let normal = ReceiverSimulator(raster: raster)
        normal.advance(to: 1.0, settings: GlitchSettings(values: ["vcr": 1, "search_speed": 1]))
        XCTAssertTrue(normal.plan().vcr!.lines.allSatisfy { ownShare($0) > 0.85 }, "1× is normal play")
    }

    func testTrackingNoiseBreaksOutWhereTheTrackStraysFurthest() {
        // The servo puts the tape where the tracking control says. The
        // picture holds while the heads are mostly on their own tracks; past
        // that the noise starts where the track bends furthest from the
        // heads' path, and spreads.
        let raster = ReceiverRaster(width: 320, activeLines: 240)
        func shares(_ offset: Double) -> [Double] {
            let sim = ReceiverSimulator(raster: raster)
            sim.advance(to: 3.0, settings: GlitchSettings(values: ["vcr": 1, "tracking_offset": offset]))
            return sim.plan().vcr!.lines.map { ownShare($0) }
        }
        // (The knob: 0.3 is half a track, 0.6 is 0.84.)
        XCTAssertTrue(shares(0).allSatisfy { $0 > 0.8 }, "tracked")
        XCTAssertTrue(shares(0.3).allSatisfy { $0 > 0.3 }, "half a track off still reads")
        let near = shares(0.6)
        let spread = near.max()! - near.min()!
        XCTAssertGreaterThan(spread, 0.03, "the track bends against the heads' path")
        // The worst end is at the top or bottom of the picture.
        let worst = near.firstIndex(of: near.min()!)!
        XCTAssertTrue(worst < 20 || worst >= near.count - 20, "worst at an end (\(worst))")
        XCTAssertTrue(shares(1).allSatisfy { $0 < 0.2 }, "a whole track off: the wrong azimuth")
    }

    func testTensionSkewsThePictureAtTheHeadSwitch() {
        // Tighter than the recorder: each line arrives a little later down
        // the field, and the next head starts on time — a jump of the
        // strain × the field: 8e-4 × 16.7 ms = 13 µs at tension 1 (the
        // knob at 57%), give or take the tension arm's hunting (±15% tight),
        // and four times that with the knob at its end.
        let raster = ReceiverRaster(width: 320, activeLines: 240)
        let L = Int64(raster.totalLines)
        func jumps(_ knob: Double) -> (jump: [Double], between: Double) {
            let sim = ReceiverSimulator(raster: raster)
            sim.advance(to: 2.0, settings: GlitchSettings(values: ["vcr": 1, "back_tension": knob]))
            let last = Int64((2.0 + ReceiverSimulator.warmup) * NTSCTiming.fieldRate) - 2
            var out: [Double] = [], between = 0.0
            for f in (last - 40)...last {
                let sw = f * L + L - Int64((3.5 * raster.scale).rounded())
                out.append(sim.timebaseError(sw) - sim.timebaseError(sw - 1))
                between = max(between, abs(sim.timebaseError(sw - 2) - sim.timebaseError(sw - 1)))
            }
            return (out, between)
        }
        func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(a.count) }
        let one = jumps(TapeParams.knob(forAmount: 1, gain: TransportParams.tensionTopEnd))
        XCTAssertEqual(mean(one.jump), -13.3, accuracy: 2.2, "skew at the switch")
        XCTAssertLessThan(one.between, 0.15, "smooth between")
        XCTAssertEqual(mean(jumps(0.5).jump), -6.7, accuracy: 1.1, "half the knob is as it always was")
        XCTAssertEqual(mean(jumps(1).jump), -53, accuracy: 9, "the end of the knob: a stretched tape")
        // Slack, the tension arm hunts: the jump wanders from field to
        // field, which is what waves the top of the picture.
        let slack = jumps(-1).jump, tight = jumps(1).jump
        func spread(_ a: [Double]) -> Double { (a.max()! - a.min()!) / abs(mean(a)) }
        XCTAssertGreaterThan(mean(slack), 30)
        XCTAssertGreaterThan(spread(slack), 0.3, "slack tape flag-waves")
        XCTAssertLessThan(spread(tight), 0.25, "tight tape holds its hook")
    }

    func testTheCompensatorKeepsSyncThroughOxideFlaws() {
        // What the dropout compensator replays is the line before, sync
        // pulse and all: a flake over the sync tip costs nothing while it
        // is on. Off, every one of them is a line whose sync is noise (and
        // Oxide flaws tore the picture into bands either way, before).
        let raster = ReceiverRaster(width: 320, activeLines: 240)
        let L = raster.totalLines
        func loss(_ values: [String: Double]) -> Double {
            let sim = ReceiverSimulator(raster: raster)
            sim.advance(to: 1, settings: GlitchSettings(values: values.merging(["vcr": 1]) { a, _ in a }))
            let f0 = Int64((1 + ReceiverSimulator.warmup) * NTSCTiming.fieldRate) - 21
            var sum = 0.0
            for f in f0..<(f0 + 20) { for i in 0..<L { sum += sim.signalLoss(f * Int64(L) + Int64(i)) } }
            return sum / Double(20 * L)
        }
        let clean = loss([:]), on = loss(["tape_dropouts": 1]), off = loss(["tape_dropouts": 1, "dropout_compensation": 0])
        XCTAssertEqual(on, clean, accuracy: 0.002, "compensated: sync as on a tape without flaws")
        XCTAssertGreaterThan(off, on + 0.02, "uncompensated: \(off) of the sync lost, against \(on)")
    }

    func testOlderLooksKeepTheirBackTension() {
        // Before look version 4 the knob ran straight to ±1; a saved value
        // becomes the position that stretches the tape the same.
        for k in [-1.0, -0.77, -0.5, -0.2, 0, 0.3, 0.5, 0.771, 1] {
            let now = GlitchSettings.upgraded(["back_tension": k], lookVersion: 3)["back_tension"]!
            XCTAssertEqual(TransportParams(GlitchSettings(values: ["back_tension": now])).tension, k, accuracy: 1e-6)
            XCTAssertEqual(GlitchSettings.upgraded(["back_tension": k], lookVersion: 4)["back_tension"]!, k)
        }
        XCTAssertEqual(TransportParams(GlitchSettings(values: ["back_tension": -1])).tension, -4, accuracy: 1e-6)
    }

    func testAStickyTapeGrabsAndLetsGo() {
        // Not a jitter on every line: the tape plays clean, sticks at a gummy
        // patch (squeal, tension climbing), and tears loose with a lurch.
        let raster = ReceiverRaster(width: 320, activeLines: 240)
        let L = Int64(raster.totalLines)
        /// Each field's largest line-to-line timing step, over four seconds.
        func steps(_ sticky: Double) -> [Double] {
            let sim = ReceiverSimulator(raster: raster)
            var out: [Double] = []
            for n in 1...24 {
                let time = Double(n) / 6
                sim.advance(to: time, settings: GlitchSettings(values: ["vcr": 1, "tape_sticky": sticky]))
                let last = Int64((time + ReceiverSimulator.warmup) * NTSCTiming.fieldRate) - 2
                for f in (last - 9)...last {
                    let j0 = f * L
                    // (Not across the head switch, where the skew jumps back.)
                    out.append((1..<(Int(L) - 8)).map { i in
                        abs(sim.timebaseError(j0 + Int64(i)) - sim.timebaseError(j0 + Int64(i) - 1))
                    }.max()!)
                }
            }
            return out
        }
        XCTAssertLessThan(steps(0).max()!, 0.01, "smooth tape")
        let some = steps(0.35), full = steps(1)
        func share(_ a: [Double], over x: Double) -> Double { Double(a.filter { $0 > x }.count) / Double(a.count) }
        // Mostly calm at a low setting, with episodes; busier at full, and
        // never every field.
        XCTAssertLessThan(share(some, over: 0.02), 0.5, "calm between grabs")
        XCTAssertGreaterThan(share(some, over: 0.02), 0.02, "but it does grab")
        XCTAssertGreaterThan(share(full, over: 0.02), share(some, over: 0.02), "more often at full")
        XCTAssertLessThan(share(full, over: 0.02), 0.9, "still in episodes")
        XCTAssertGreaterThan(full.max()!, 1.5, "letting go lurches (µs in a line)")
        // The same place on the tape every play; elsewhere on another cassette.
        let c = Int64(40)
        let tape = TapeParams(GlitchSettings(values: ["tape_sticky": 1]))
        let other = TapeParams(GlitchSettings(values: ["tape_sticky": 1, "tape_seed": 5]))
        XCTAssertEqual(StickyTape.patch(c, tape)?.start, StickyTape.patch(c, tape)?.start)
        XCTAssertNotEqual(StickyTape.patch(c, tape)?.start, StickyTape.patch(c, other)?.start)
        XCTAssertNil(StickyTape.patch(c, TapeParams(GlitchSettings(values: [:]))))
    }

    func testFlutterBendsThePictureSmoothly() {
        // A drum is a flywheel: its timing wanders by microseconds down a
        // field but hardly at all from one line to the next. (It used to be
        // a third noise, and read as every line displaced at random.)
        let raster = ReceiverRaster(width: 320, activeLines: 240)
        let L = Int64(raster.totalLines)
        let sim = ReceiverSimulator(raster: raster)
        sim.advance(to: 1.0, settings: GlitchSettings(values: ["vcr": 1, "transport_flutter": 1]))
        let f = Int64((1.0 + ReceiverSimulator.warmup) * NTSCTiming.fieldRate) - 2
        let e = (0..<(Int(L) - 8)).map { sim.timebaseError(f * L + Int64($0)) }
        let swing = e.max()! - e.min()!
        let step = zip(e.dropFirst(), e).map { abs($0 - $1) }.max()!
        XCTAssertGreaterThan(swing, 3, "it sways (µs across a field)")
        XCTAssertLessThan(step, swing / 12, "smoothly: \(step) µs a line against \(swing) across the field")
        // And the shape mostly stands in the picture: the same lines of the
        // field after next are bent much the same way.
        let later = (0..<(Int(L) - 8)).map { sim.timebaseError((f + 2) * L + Int64($0)) }
        func centered(_ a: [Double]) -> [Double] { let m = a.reduce(0, +) / Double(a.count); return a.map { $0 - m } }
        let a = centered(e), b = centered(later)
        let dot = zip(a, b).map { $0 * $1 }.reduce(0, +)
        let corr = dot / (a.map { $0 * $0 }.reduce(0, +) * b.map { $0 * $0 }.reduce(0, +)).squareRoot()
        XCTAssertGreaterThan(corr, 0.6, "a frame later it is nearly the same shape")
    }

    func testAChewedEdgeLosesTheControlTrack() {
        // The control head misses pulses on a crinkled bottom edge (and
        // fakes some), so the servo loses its hold and the tracking wanders.
        let raster = ReceiverRaster(width: 320, activeLines: 240)
        func wander(_ edge: Double) -> Double {
            let sim = ReceiverSimulator(raster: raster)
            var worst = 0.0
            for i in 0..<40 {
                sim.advance(to: 1 + Double(i) * 0.1,
                            settings: GlitchSettings(values: ["vcr": 1, "tape_edge_damage": edge]))
                let d = sim.plan().vcr!.lines.map { Double($0.delta0) }
                worst = max(worst, abs(d.reduce(0, +) / Double(d.count)))
            }
            return worst
        }
        XCTAssertLessThan(wander(0), 0.15, "a good edge holds the tracking")
        XCTAssertGreaterThan(wander(1), 0.3, "a chewed one doesn't")
    }

    func testAWornTapeKeepsItsTracking() {
        // Worn oxide reads weaker everywhere, but the control amplifier has
        // gain to spare: the servo holds. (It once lost every other pulse
        // and, holding each correction through the gaps, swung the tape
        // further each frame until the picture was noise.)
        let L = ReceiverRaster(width: 320, activeLines: 240).totalLines
        for extra in [["tape_wear": 1.0],
                      ["tape_wear": asBefore("tape_wear", 0.7), "tape_dropouts": asBefore("tape_dropouts", 0.45),
                       "tape_scratches": asBefore("tape_scratches", 0.5),
                       "tape_edge_damage": asBefore("tape_edge_damage", 0.35)]] {
            let t = TransportSimulator(linesPerField: L, seed: 0x4E54_5343_5254,
                                       settings: GlitchSettings(values: extra.merging(["vcr": 1]) { a, _ in a }))
            t.reset()
            var worst = 0.0
            for f in 1...Int64(30 * 60) {
                t.advance(through: f * Int64(L))
                worst = max(worst, abs(t.line(f * Int64(L)).delta))
            }
            XCTAssertLessThan(worst, 0.1, "\(extra)")
        }
    }

    func testALostControlTrackDriftsButNeverRunsAway() {
        // With pulses missing and faked, the tape wanders off its tracks —
        // a slow drift with the capstan's own speed, not a swing that grows.
        let L = ReceiverRaster(width: 320, activeLines: 240).totalLines
        let t = TransportSimulator(linesPerField: L, seed: 0x4E54_5343_5254,
                                   settings: GlitchSettings(values: ["vcr": 1, "tape_edge_damage": 1,
                                                                     "tape_mold": 1, "tape_wear": 1]))
        t.reset()
        var worst = 0.0
        for f in 1...Int64(60 * 60) {
            t.advance(through: f * Int64(L))
            worst = max(worst, abs(t.line(f * Int64(L)).delta))
            XCTAssertLessThan(abs(t.line(f * Int64(L)).tbe), NTSCTiming.line / 2)
        }
        XCTAssertLessThan(worst, 60 * 0.15 * 30 + 2, "bounded by the capstan's range")
    }

    func testEPHoldsItsSyncNearlyAsWellAsSP() {
        // A worn, creased tape in a dirty deck: EP's narrow track leaves it a little
        // less margin, not a cliff. (The neighbors' carriers once counted as
        // noise, holding even a clean EP tape just above the FM threshold.)
        let raster = ReceiverRaster(width: 320, activeLines: 240)
        let L = raster.totalLines
        func loss(_ speed: Int) -> Double {
            let sim = ReceiverSimulator(raster: raster)
            sim.advance(to: 3, settings: GlitchSettings(values: [
                // The tape this was calibrated on, from before the damage
                // knobs' top ends were strengthened.
                "vcr": 1, "tape_speed": Double(speed), "tape_wear": asBefore("tape_wear", 0.63),
                "tape_dropouts": TapeParams.knob("tape_dropouts", forAmount: 0.72), "tape_scratches": asBefore("tape_scratches", 1),
                "tape_creases": asBefore("tape_creases", 0.95), "tape_mold": 0.13, "tape_vaseline": 0.14,
                // No Dirt buildup: a clog lodging in these thirty fields
                // is chance (with it at 0.18 EP's loss ran 0.06–0.7 from
                // cassette to cassette, SP's 0.04–0.4), and says nothing
                // about the margin this is checking.
                "back_tension": 0, "head_dirt": 0.4, "head_wear": 0.15, "head_mismatch": 0.3,
                "dirt_buildup": 0, "head_switch": 7.9]))
            let f0 = Int64((3 + ReceiverSimulator.warmup) * NTSCTiming.fieldRate) - 31
            var sum = 0.0
            for f in f0..<(f0 + 30) { for i in 0..<L { sum += sim.signalLoss(f * Int64(L) + Int64(i)) } }
            return sum / Double(30 * L)
        }
        let sp = loss(0), ep = loss(2)
        XCTAssertLessThan(sp, 0.08)
        XCTAssertGreaterThan(ep, sp, "EP is less forgiving")
        XCTAssertLessThan(ep, 0.25, "but not a cliff (was 0.33)")
    }
}
