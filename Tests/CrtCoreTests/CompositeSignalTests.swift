import XCTest
@testable import CrtCore

/// The picture as a composite signal (RF input): the set's decode filters
/// and the Edge crawl and Color knobs, before anything is drawn.
final class CompositeSignalTests: XCTestCase {

    private func signal(_ values: [String: Double]) -> CompositeSignal {
        CompositeSignal(GlitchSettings(values: values))
    }
    /// Cycles a sample for a frequency in MHz.
    private func f(_ mhz: Double) -> Double { mhz * CompositeSignal.sampleUS }
    private let carrier = 1.0 / Double(CompositeSignal.samplesPerCycle)

    /// The switch: off by default, and off the knobs do nothing.
    func testTheSwitch() {
        XCTAssertFalse(signal([:]).on)
        XCTAssertTrue(signal(["rf": 1]).on)
        let off = signal(["rf_crawl": 0.8, "rf_color": 3])
        XCTAssertEqual(off.crawl, 0); XCTAssertEqual(off.color, 1); XCTAssertEqual(off.colorInSignal, 1)
        let on = signal(["rf": 1])
        XCTAssertEqual(on.crawl, 0); XCTAssertEqual(on.color, 1, "the color as sent, by default")
        XCTAssertTrue(GlitchSettings.timingIDs.contains("rf"), "the tuner's noise reaches the sync circuits")
        let idle = signal(["rf_smear": 1, "rf_soft": 1, "rf_offset": 1])
        XCTAssertEqual(idle.smear, 0); XCTAssertEqual(idle.soft, 0); XCTAssertEqual(idle.offset, 0)
        XCTAssertEqual(idle.burstGain, 1)
    }

    /// Tuner smear: the color's lateness grows evenly along the knob, from
    /// none to about 0.9 µs; the weights are one color's worth; and without
    /// it the signal's color is filtered exactly as its brightness is.
    func testTunerSmearMakesTheColorLate() {
        func late(_ k: Double) -> Double {
            let w = signal(["rf": 1, "rf_smear": k]).smearKernel
            XCTAssertEqual(w.reduce(0, +), 1, accuracy: 1e-9)
            let cycles = w.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
            return cycles / NTSCTiming.subcarrierMHz               // µs
        }
        XCTAssertEqual(late(0), 0)
        XCTAssertEqual(signal(["rf": 1]).smearKernel.first, 1)
        var last = 0.0
        for k in [0.25, 0.5, 0.75, 1.0] {
            let v = late(k)
            XCTAssertGreaterThan(v, last + 0.12, "\(k)")
            last = v
        }
        XCTAssertEqual(last, 0.92, accuracy: 0.05)
        // The table: brightness's two columns are the plain filters, with
        // or without smear; the color's two are the same without it, and
        // reach further back with it.
        let span = CompositeSignal.tapSpan, left = CompositeSignal.tapLeft, r = CompositeSignal.tapRadius
        let plain = signal(["rf": 1]), smeared = signal(["rf": 1, "rf_smear": 1])
        let p = plain.signalTaps, q = smeared.signalTaps
        XCTAssertEqual(p.count, 4 * span)
        XCTAssertEqual(Array(p[0..<2 * span]), Array(q[0..<2 * span]))
        XCTAssertEqual(Array(p[2 * span..<4 * span]), Array(p[0..<2 * span]))
        XCTAssertEqual(Array(p[left - r...left + r]), plain.taps.luma)
        XCTAssertEqual(plain.tapsBefore, r); XCTAssertEqual(smeared.tapsBefore, left)
        XCTAssertTrue(p[0..<left - r].allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(q[3 * span..<3 * span + left - r].map(abs).reduce(0, +), 0.2, "color from further back")
        // Still one color's worth: the color column sums as the plain one.
        XCTAssertEqual(q[3 * span..<4 * span].reduce(0, +), p[span..<2 * span].reduce(0, +), accuracy: 1e-4)
    }

    /// Softness takes the brightness's detail, more at each setting, and
    /// nothing else: levels hold and the color's filter is as it was.
    func testSoftnessTakesDetailOnly() {
        let plain = signal(["rf": 1]).taps
        var last = CompositeSignal.gain(plain.luma, cyclesPerSample: f(1.5))
        for k in [0.25, 0.5, 0.75, 1.0] {
            let t = signal(["rf": 1, "rf_soft": k]).taps
            XCTAssertEqual(CompositeSignal.gain(t.luma, cyclesPerSample: 0), 1, accuracy: 1e-5)
            let g = CompositeSignal.gain(t.luma, cyclesPerSample: f(1.5))
            XCTAssertLessThan(g, last - 0.1, "\(k)")
            XCTAssertEqual(t.chroma, plain.chroma)
            last = g
        }
        XCTAssertLessThan(last, 0.05, "1.5 MHz gone at the top")
        XCTAssertGreaterThan(CompositeSignal.gain(signal(["rf": 1, "rf_soft": 1]).taps.luma, cyclesPerSample: f(0.4)), 0.85)
    }

    /// Tuner offset: less of everything at the subcarrier (down to 15%:
    /// under the color killer's third from about 0.8), the picture's color
    /// fading along the way, and detail at lower contrast — but not gone,
    /// which is Softness — with levels holding.
    func testTunerOffsetStarvesTheColorAndHazesThePicture() {
        XCTAssertTrue(GlitchSettings.timingIDs.contains("rf_offset"), "the color circuits follow the burst")
        var lastBurst = 1.0, lastColor = 1.0
        var lastDetail = CompositeSignal.gain(signal(["rf": 1]).taps.luma, cyclesPerSample: f(1.5))
        for k in [0.25, 0.5, 0.75, 1.0] {
            let sig = signal(["rf": 1, "rf_offset": k])
            XCTAssertLessThan(sig.burstGain, lastBurst - 0.15, "\(k)")
            XCTAssertLessThan(sig.colorInSignal, lastColor - 0.08, "\(k)")
            XCTAssertEqual(CompositeSignal.gain(sig.taps.luma, cyclesPerSample: 0), 1, accuracy: 1e-5)
            let detail = CompositeSignal.gain(sig.taps.luma, cyclesPerSample: f(1.5))
            XCTAssertLessThan(detail, lastDetail - 0.05, "\(k)")
            lastBurst = sig.burstGain; lastColor = sig.colorInSignal; lastDetail = detail
        }
        XCTAssertEqual(lastBurst, 0.15, accuracy: 1e-9)
        XCTAssertGreaterThan(signal(["rf": 1, "rf_offset": 0.7]).burstGain, 0.34, "the killer still holds off at 70%")
        XCTAssertLessThan(signal(["rf": 1, "rf_offset": 0.9]).burstGain, 0.25, "and has the color by 90%")
        XCTAssertGreaterThan(lastDetail, 0.2, "lower contrast, not gone")
    }

    /// Six samples a subcarrier cycle: 21.5 MHz.
    func testTheSamplingRate() {
        XCTAssertEqual(1 / CompositeSignal.sampleUS, 6 * NTSCTiming.subcarrierMHz, accuracy: 1e-9)
        XCTAssertEqual(f(NTSCTiming.subcarrierMHz), carrier, accuracy: 1e-12)
    }

    /// The set's brightness filter passes the picture and keeps the
    /// subcarrier out; its color filter passes the color's band and keeps
    /// out the brightness's detail and the decoding's leftovers (the
    /// brightness itself lands at the subcarrier after decoding, the color
    /// again at twice it).
    func testTheDecodeFilters() {
        let t = signal(["rf": 1]).taps
        XCTAssertEqual(t.luma.count, 2 * CompositeSignal.tapRadius + 1)
        XCTAssertEqual(t.chroma.count, t.luma.count)
        for taps in [t.luma, t.chroma] {
            for i in 0..<taps.count / 2 { XCTAssertEqual(taps[i], taps[taps.count - 1 - i], accuracy: 1e-7) }
        }
        XCTAssertEqual(CompositeSignal.gain(t.luma, cyclesPerSample: 0), 1, accuracy: 1e-5)
        XCTAssertGreaterThan(CompositeSignal.gain(t.luma, cyclesPerSample: f(1.0)), 0.85)
        XCTAssertEqual(CompositeSignal.gain(t.luma, cyclesPerSample: f(2.1)), 0.5, accuracy: 0.06)
        for mhz in [3.58, 4.2, 5.4, 7.16, 10.0] {
            XCTAssertLessThan(abs(CompositeSignal.gain(t.luma, cyclesPerSample: f(mhz))), 0.01, "luma at \(mhz) MHz")
        }
        XCTAssertEqual(CompositeSignal.gain(t.chroma, cyclesPerSample: 0), 1, accuracy: 1e-5)
        XCTAssertEqual(CompositeSignal.gain(t.chroma, cyclesPerSample: f(0.85)), 0.5, accuracy: 0.06)
        for mhz in [1.8, 2.5, 3.58, 5.0, 7.16] {
            XCTAssertLessThan(abs(CompositeSignal.gain(t.chroma, cyclesPerSample: f(mhz))), 0.02, "chroma at \(mhz) MHz")
        }
    }

    /// Edge crawl makes more of the signal's fast changes, more at each
    /// setting: harder edges, and what the set takes for color (the fringes
    /// and the noise) up to 2.2 times — not the four times it once was,
    /// which read as added color. Levels hold; a steady color still stays
    /// out of the brightness (the notch); and the picture's own color goes
    /// into the signal that much weaker, so it comes out unchanged.
    func testEdgeCrawlRaisesEdgesAndFringesAndLeavesTheColor() {
        var lastFringe = 1.0
        var lastEdge = CompositeSignal.gain(signal(["rf": 1]).taps.luma, cyclesPerSample: carrier / 2)
        XCTAssertEqual(CompositeSignal.gain(signal(["rf": 1]).taps.chroma, cyclesPerSample: 0), 1, accuracy: 1e-5)
        for k in [0.25, 0.5, 0.75, 1.0] {
            let sig = signal(["rf": 1, "rf_crawl": k])
            let t = sig.taps
            XCTAssertEqual(CompositeSignal.gain(t.luma, cyclesPerSample: 0), 1, accuracy: 1e-5, "\(k): levels hold")
            XCTAssertLessThan(abs(CompositeSignal.gain(t.luma, cyclesPerSample: carrier)), 0.02,
                              "\(k): a steady color stays out of the brightness")
            // What comes out of the color filter for each unit at the
            // subcarrier going in: the fringes and the noise.
            let fringe = CompositeSignal.gain(t.chroma, cyclesPerSample: 0)
            let edge = CompositeSignal.gain(t.luma, cyclesPerSample: carrier / 2)
            XCTAssertGreaterThan(fringe, lastFringe + 0.2, "\(k): stronger fringes")
            XCTAssertGreaterThan(edge, lastEdge * 1.15, "\(k): harder edges")
            XCTAssertEqual(sig.colorInSignal * fringe, 1, accuracy: 1e-5, "\(k): the picture's color as it was")
            lastFringe = fringe; lastEdge = edge
        }
        XCTAssertEqual(lastFringe, 2.2, accuracy: 0.01)
        XCTAssertLessThan(lastFringe, 2.5, "not the color it once added")
        // The notch: at the top the brightness filter passes what lies
        // either side of the subcarrier's band (where a change of color
        // puts its sidebands: the dots beside the edge); tuned plain, the
        // low-pass passes neither.
        let plain = signal(["rf": 1]).taps.luma, notch = signal(["rf": 1, "rf_crawl": 1]).taps.luma
        for mhz in [2.6, 4.4] {
            XCTAssertLessThan(abs(CompositeSignal.gain(plain, cyclesPerSample: f(mhz))), 0.3, "\(mhz) MHz")
            XCTAssertGreaterThan(abs(CompositeSignal.gain(notch, cyclesPerSample: f(mhz))), 1.0, "\(mhz) MHz")
        }
    }

    /// Color is the picture's color going into the signal: none at 0, as
    /// sent at 1, four times at the top — whatever Edge crawl says, and
    /// without touching the filters (so not the fringes or the noise).
    func testColorIsThePicturesOwn() {
        for crawl in [0.0, 0.5, 1.0] {
            let plain = signal(["rf": 1, "rf_crawl": crawl])
            for c in [0.0, 0.5, 1.0, 2.0, 4.0] {
                let sig = signal(["rf": 1, "rf_crawl": crawl, "rf_color": c])
                XCTAssertEqual(sig.colorInSignal * CompositeSignal.gain(sig.taps.chroma, cyclesPerSample: 0), c,
                               accuracy: 1e-4, "crawl \(crawl), color \(c)")
                XCTAssertEqual(sig.taps.luma, plain.taps.luma); XCTAssertEqual(sig.taps.chroma, plain.taps.chroma)
            }
        }
        XCTAssertEqual(signal(["rf": 1, "rf_color": 9]).color, CompositeSignal.mostColor)
    }

    /// The Connection picker: each condition is found again from its
    /// values; they run from nothing in the way to a rough antenna socket,
    /// each RF one with less signal, more ghost, more crawl and more color.
    func testTheConnectionsRunFromDirectToARoughSocket() {
        let keys = VcrCondition.connectionKeys
        let base = GlitchParam.defaultValues
        let list = VcrCondition.connections
        XCTAssertEqual(list.first?.applied(to: base, keys: keys), base)
        XCTAssertEqual(list.map { signal($0.applied(to: base, keys: keys)).on }, [false, true, true, true])
        var lastStrength = 1.01, lastGhost = -0.01, lastCrawl = -0.01, lastColor = 1.0
        for c in list {
            let v = c.applied(to: ["rf": 1, "rf_crawl": 0.9, "rf_color": 3.9, "hum": 0.9], keys: keys)
            XCTAssertEqual(VcrCondition.matching(list, keys: keys, in: v)?.name, c.name)
            let s = GlitchSettings(values: v)
            guard signal(v).on else {
                XCTAssertEqual(s["signal_strength"], 1, c.name); XCTAssertEqual(s["hum"], 0, c.name)
                XCTAssertEqual(s["rf_color"], 1, c.name)
                continue
            }
            XCTAssertLessThan(s["signal_strength"], lastStrength, c.name)
            XCTAssertGreaterThan(s["ghost_level"], lastGhost, c.name)
            XCTAssertGreaterThan(s["rf_crawl"], lastCrawl, c.name)
            XCTAssertGreaterThan(s["rf_color"], lastColor, c.name)
            lastStrength = s["signal_strength"]; lastGhost = s["ghost_level"]
            lastCrawl = s["rf_crawl"]; lastColor = s["rf_color"]
        }
    }
}
