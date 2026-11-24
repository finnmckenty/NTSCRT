import Foundation

/// NTSC line timing (SMPTE 170M), in µs. The simulated set keeps these
/// proportions whatever the raster height: features sit at the same
/// fraction of a line, so a 1 µs ghost displaces the picture by the same
/// fraction of its width as on a real set.
public enum NTSCTiming {
    public static let line = 63.556
    public static let sync = 4.7
    public static let burstStart = 5.3
    public static let burstEnd = 7.8
    /// The set's burst gate: a 4 µs window around the burst, keyed from its
    /// own horizontal flyback — so a horizontal phase error slides it off
    /// the burst (color fades, then the killer cuts in) and onto picture.
    public static let gateStart = 4.55
    public static let gateEnd = 8.55
    public static let activeStart = 9.4
    public static let activeLength = 52.656
    public static var activeEnd: Double { activeStart + activeLength }
    public static let equalizingPulse = 2.3
    public static let broadPulse = 27.1
    public static let fieldRate = 60000.0 / 1001.0          // 59.94 Hz (color)
    public static let linesPerField = 262.5
    public static let subcarrierMHz = 315.0 / 88.0          // 3.579545
    /// Color burst direction in the decoder's I/Q plane: 180° on the B−Y
    /// axis, which is (sin 33°, −cos 33°) in I/Q.
    public static let burstI = 0.5446390350150271
    public static let burstQ = -0.8386705679454240
    /// Burst amplitude (20 IRE) on the decoder's luma scale (black 7.5 IRE
    /// to white 100 IRE spans 0…1).
    public static let burstAmplitude = 20.0 / 92.5
}

/// The simulated set's raster: the chain input's rows are its active lines,
/// with a vertical blanking interval added in NTSC proportion (about 8% of
/// the field). NTSC-defined line counts — the 9-line vertical sync
/// interval, where the head switch happens — scale with it.
public struct ReceiverRaster: Equatable, Sendable {
    public let width: Int
    public let activeLines: Int
    public let vbiLines: Int
    /// Within-field line indices: [0, preEqEnd) pre-equalizing,
    /// [preEqEnd, vsyncEnd) serrated vertical sync, [vsyncEnd, postEqEnd)
    /// post-equalizing, then blanking lines carrying burst, the last of
    /// which is line 21 (closed captions). Active picture follows.
    public let preEqEnd: Int
    public let vsyncEnd: Int
    public let postEqEnd: Int

    public var totalLines: Int { activeLines + vbiLines }
    /// Raster lines per NTSC line.
    public var scale: Double { Double(totalLines) / NTSCTiming.linesPerField }
    public var ccLine: Int { vbiLines - 1 }

    public init(width: Int, activeLines: Int) {
        self.width = max(1, width)
        self.activeLines = max(1, activeLines)
        let v = max(12, Int((Double(self.activeLines) * 20.0 / 242.5).rounded()))
        vbiLines = v
        let s = Double(self.activeLines + v) / NTSCTiming.linesPerField
        let eq = max(1, Int((3 * s).rounded()))
        preEqEnd = eq
        vsyncEnd = 2 * eq
        postEqEnd = 3 * eq
    }

    enum LineKind { case equalizing, vsync, normal }

    func kind(ofFieldLine jf: Int) -> LineKind {
        if jf < preEqEnd { return .equalizing }
        if jf < vsyncEnd { return .vsync }
        if jf < postEqEnd { return .equalizing }
        return .normal
    }

    /// Fraction of the line spent at sync level.
    func syncDuty(ofFieldLine jf: Int) -> Double {
        switch kind(ofFieldLine: jf) {
        case .equalizing: return 2 * NTSCTiming.equalizingPulse / NTSCTiming.line
        case .vsync:      return 2 * NTSCTiming.broadPulse / NTSCTiming.line
        case .normal:     return NTSCTiming.sync / NTSCTiming.line
        }
    }

    /// Lines without burst: the equalizing and vertical sync lines.
    func hasBurst(fieldLine jf: Int) -> Bool { jf >= postEqEnd }
}

/// One screen row of the field to display: where the TV's horizontal scan
/// started relative to the signal. Mirrors the GPU struct (12 × 4 bytes).
public struct GlitchRow: Equatable {
    /// µs from the sync edge of signal line `fieldLine` to the start of the
    /// TV's line (its flyback). 0 when locked.
    public var u0: Float
    /// Within-field index of that signal line (VBI lines first).
    public var fieldLine: Int32
    /// Lengths (µs) of the previous, this and the next signal line —
    /// different from 63.556 only where the tape's time base jumps.
    public var lenPrev: Float
    public var lenCur: Float
    public var lenNext: Float
    /// Reception (antenna) noise on this line, IRE RMS.
    public var noiseIRE: Float
    /// Mains hum on this line, IRE.
    public var humIRE: Float
    /// Fraction of the burst reaching the TV (the VCR's color killer can
    /// stop it).
    public var burstScale: Float
    var pad0: Float = 0
    /// Where the burst gate sits relative to the scan line start (µs). The
    /// gate is keyed from a fast phase loop that follows the incoming sync,
    /// so it stays on the burst through a slow or standing phase error (a
    /// sliding picture keeps its color) but not through cycle slips (a torn
    /// picture's color goes wild).
    public var gateShift: Float = 0
    var pad1: Float = 0, pad2: Float = 0
}

/// Everything the GPU stage needs for one displayed field.
public struct GlitchFieldPlan {
    public var raster: ReceiverRaster
    public var rows: [GlitchRow]
    /// The VCR's view of the field's active lines, when it is playing.
    public var vcr: VcrFieldPlan?
    /// Color reference state entering the first visible row: the phase
    /// error of the TV's 3.58 MHz oscillator (rad), the ACC gain, the
    /// color killer's integrator and its on/off state.
    public var chromaPhase: Float
    public var chromaGain: Float
    public var killer: Float
    public var colorOn: Bool
    /// Signal amplitude after AGC (falls only on very weak signals).
    public var pictureGain: Float
    public var ccBits: UInt32
    public var fieldIndex: UInt32
    public var settings: GlitchSettings
}

// MARK: - deterministic noise

/// Hash-based randomness keyed by position, never by call order — so any
/// moment of the simulation can be recomputed exactly (exports, scrubbing).
enum GlitchRandom {
    @inline(__always)
    static func mix(_ z0: UInt64) -> UInt64 {
        var z = z0 &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    @inline(__always)
    static func uniform(_ seed: UInt64, _ purpose: UInt64, _ a: Int64, _ b: Int64 = 0) -> Double {
        let h = mix(seed ^ mix(purpose ^ mix(UInt64(bitPattern: a) ^ mix(UInt64(bitPattern: b)))))
        return Double(h >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    @inline(__always)
    static func gauss(_ seed: UInt64, _ purpose: UInt64, _ a: Int64, _ b: Int64 = 0) -> Double {
        let u1 = max(1e-12, uniform(seed, purpose, a, b))
        let u2 = uniform(seed, purpose &+ 0x51, a, b)
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    /// Smooth 1-D value noise in [−1, 1] with unit lattice spacing.
    static func value(_ seed: UInt64, _ purpose: UInt64, _ x: Double) -> Double {
        let i = floor(x)
        let f = x - i
        let a = uniform(seed, purpose, Int64(i)) * 2 - 1
        let b = uniform(seed, purpose, Int64(i) + 1) * 2 - 1
        let s = f * f * (3 - 2 * f)
        return a + (b - a) * s
    }

    /// Standard normal CDF.
    static func phi(_ x: Double) -> Double { 0.5 * erfc(-x / 2.0.squareRoot()) }
}

// MARK: - the receiver

/// Simulates the TV's synchronization circuits, scan line by scan line,
/// against a signal whose timing and level the tape and reception model
/// can disturb. Design after Trevor Blackwell's analogtv (xscreensaver):
/// glitches are never drawn — they are how these circuits respond.
///
/// - Horizontal: an AFC phase-locked loop (sync-edge phase detector,
///   proportional + integral correction, a VCO with limited range). Within
///   its range it locks; past it the picture slides as the loop strains,
///   then tears as it slips cycles. Its response time sets how far it bends
///   chasing a VCR's head-switch timing jump (flagging).
/// - Vertical: a free-running relaxation oscillator triggered early by the
///   integrated vertical sync pulse — injection locking, as in real sets.
///   Too fast and it fires before sync arrives; too slow and sync can't pull
///   it in: either way the picture rolls.
/// - Noise acts on sync detection as it would on a slicing sync separator:
///   missed pulses, false triggers from noise peaks, edge jitter.
///
/// State depends only on (settings over time, seed), never on the picture,
/// so any moment can be reproduced by simulating from zero. The set runs for
/// `warmup` seconds before time zero, so time zero already shows a set that
/// has been on — a mis-set vertical hold is already rolling.
public final class ReceiverSimulator {
    public let raster: ReceiverRaster
    public let seed: UInt64
    public static let warmup = 2.0

    private let L: Int
    private let H = NTSCTiming.line
    private let usPerSecond: Double

    // Horizontal AFC.
    private var r: Int64 = 0                // next TV line to scan
    private var theta = 0.0                 // TV line r starts at signal time r·H + θ
    private var integ = 0.0                 // integral term, µs per line
    // Vertical oscillator: lines into the set's own field, plus the sync
    // integrator and whether it is currently above its threshold.
    private var vPhase = 0.0
    private var vInteg = 0.0
    private var vAbove = false
    private var triggers: [Int64] = []
    // The burst-key loop's phase error estimate (µs), and its log.
    private var gateErr = 0.0
    private var gateLog: [Double]
    // Recent TV line starts, for building the displayed field.
    private var thetaLog: [Double]
    private let logCap: Int

    private var knobs: Knobs
    /// The deck's heads, as the tape plays (only while the VCR is on).
    private let deck = DeckSimulator(settings: GlitchSettings())
    /// The tape's motion past the drum (only while the VCR is on).
    private let transport: TransportSimulator
    /// Creases each recent field's track crosses.
    private var foldCache: [(field: Int64, folds: [TapeSurface.Fold])] = []
    /// Each deck's drum shape (drumLumps), by its seed.
    private var lumpCache: [(seed: UInt64, lumps: [(size: Double, phase: Double)])] = []
    /// Within-field line where a healthy, locked set's vertical oscillator
    /// fires; the picture's vertical framing is relative to it.
    public let nominalTrigger: Int

    /// Seconds since time zero (negative during warm-up).
    public var time: Double { (Double(r) * H + theta) / usPerSecond - Self.warmup }

    public init(raster: ReceiverRaster, seed: UInt64 = 0x4E54_5343_5254) {
        self.raster = raster
        self.seed = seed
        L = raster.totalLines
        usPerSecond = NTSCTiming.line * Double(raster.totalLines) * NTSCTiming.fieldRate
        logCap = 4 * raster.totalLines + 64
        thetaLog = Array(repeating: 0, count: logCap)
        gateLog = Array(repeating: 0, count: logCap)
        knobs = Knobs(GlitchSettings(), raster: raster)
        transport = TransportSimulator(linesPerField: raster.totalLines, seed: seed, settings: GlitchSettings())
        nominalTrigger = Self.calibrate(raster: raster, seed: seed)
        reset()
    }

    /// Back to a freshly started set, `warmup` seconds before time zero.
    public func reset() {
        r = 0
        theta = 0
        integ = 0
        vPhase = 0
        vInteg = 0
        vAbove = false
        gateErr = 0
        triggers.removeAll()
        for i in thetaLog.indices { thetaLog[i] = 0; gateLog[i] = 0 }
        deck.reset(atField: 0)
        transport.reset()
        foldCache = []
    }

    /// Complete simulation state at a moment — small enough to keep one per
    /// second of a clip, so seeking restores the nearest instead of
    /// re-running from zero.
    public struct Snapshot {
        public let time: Double
        fileprivate let r: Int64
        fileprivate let theta: Double
        fileprivate let integ: Double
        fileprivate let vPhase: Double
        fileprivate let vInteg: Double
        fileprivate let vAbove: Bool
        fileprivate let gateErr: Double
        fileprivate let gateLog: [Double]
        fileprivate let triggers: [Int64]
        fileprivate let thetaLog: [Double]
        fileprivate let deck: DeckSimulator.Snapshot
        fileprivate let transport: TransportSimulator.Snapshot
    }

    /// `at`: the moment the set was advanced to, when the snapshot should
    /// answer for it (an advance stops up to a line past its target, so the
    /// set's own clock reads a little later).
    public func snapshot(at moment: Double? = nil) -> Snapshot {
        Snapshot(time: moment ?? time, r: r, theta: theta, integ: integ, vPhase: vPhase, vInteg: vInteg,
                 vAbove: vAbove, gateErr: gateErr, gateLog: gateLog,
                 triggers: triggers, thetaLog: thetaLog, deck: deck.snapshot(),
                 transport: transport.snapshot())
    }

    public func restore(_ s: Snapshot) {
        r = s.r; theta = s.theta; integ = s.integ; vPhase = s.vPhase; vInteg = s.vInteg
        vAbove = s.vAbove; gateErr = s.gateErr; gateLog = s.gateLog
        triggers = s.triggers; thetaLog = s.thetaLog
        deck.restore(s.deck)
        transport.restore(s.transport)
        foldCache = []
    }

    /// Run the set forward to `time` with `settings` in force since the
    /// previous call.
    public func advance(to time: Double, settings: GlitchSettings) {
        let k = Knobs(settings, raster: raster)
        if k.tape != knobs.tape || k.transport.format != knobs.transport.format { foldCache = [] }
        knobs = k
        deck.update(settings)
        transport.update(settings)
        let target = (time + Self.warmup) * usPerSecond
        while Double(r) * H + theta <= target { step() }
    }

    /// Simulate from a fresh start to `time`, with settings that may vary:
    /// `settingsAt` is sampled once per `frameDuration` exactly as a frame-
    /// by-frame advance would, so the result matches one bit for bit.
    ///
    /// `resumeFrom` continues from a snapshot taken during an earlier run of
    /// the same history; `checkpoint` is handed a snapshot about once a
    /// second (on the frame grid, so resuming from it is exact).
    public func resimulate(to time: Double, frameDuration: Double,
                           settingsAt: (Double) -> GlitchSettings,
                           resumeFrom: Snapshot? = nil,
                           checkpoint: ((Snapshot) -> Void)? = nil,
                           isCancelled: (() -> Bool)? = nil) {
        var k = 1
        if let snap = resumeFrom, frameDuration > 0 {
            restore(snap)
            k = Int((snap.time / frameDuration).rounded()) + 1
        } else {
            reset()
            advance(to: 0, settings: settingsAt(0))
            // The warmed-up set at time zero: what a looping clip comes
            // back to on every pass.
            checkpoint?(snapshot(at: 0))
        }
        guard time > 0, frameDuration > 0 else {
            // (A snapshot doesn't hold the knobs: resumed where it stops,
            // the set takes that moment's. No line is stepped.)
            if resumeFrom != nil, frameDuration > 0 { advance(to: time, settings: settingsAt(time)) }
            return
        }
        var nextCheckpoint = (self.time + 1).rounded(.down)
        while true {
            if let isCancelled, k % 30 == 0, isCancelled() { return }
            let t = min(time, Double(k) * frameDuration)
            advance(to: t, settings: settingsAt(t))
            if t >= time { break }
            if let checkpoint, t >= nextCheckpoint, t == Double(k) * frameDuration {
                checkpoint(snapshot())
                nextCheckpoint = t.rounded(.down) + 1
            }
            k += 1
        }
    }

    // MARK: one scan line

    private func step() {
        let k = knobs
        let tau = Double(r) * H + theta
        // The tape moves on (a few lines ahead of the scan, so everything
        // that asks where it was finds it already there).
        if k.vcr { transport.advance(through: Int64((tau / H).rounded()) + 3) }

        // The signal line whose sync edge is nearest the TV's line start.
        var j = Int64((tau / H).rounded())
        var e = timebaseError(j)
        var edge = Double(j) * H + e
        if tau - edge > H / 2 { j += 1; e = timebaseError(j); edge = Double(j) * H + e }
        else if edge - tau > H / 2 { j -= 1; e = timebaseError(j); edge = Double(j) * H + e }
        let jf = Int(posmod(j, Int64(L)))
        if k.vcr { deck.advance(toField: floordiv(j, Int64(L)) + 1) }
        let loss = signalLoss(j)
        let sigma = noiseSigma(loss: loss)
        // The separator slices halfway down the 40 IRE sync pulse, after
        // a ~0.5 MHz low-pass that keeps about a third of the video noise.
        let sigmaSep = sigma * 0.35
        // Hum the set's DC restoration doesn't remove shifts the whole
        // signal against the fixed slice level: sync tips rise toward it
        // (missed pulses) or blanking sinks toward it (false ones).
        let humNow = hum(atSignalTime: tau)
        let humShift = 0.4 * humNow
        let syncMargin = 20 - humShift          // sync tip below the slice
        let blankMargin = 20 + humShift         // blanking above the slice
        let pDetect = sigmaSep > 0 ? GlitchRandom.phi(syncMargin / sigmaSep) : (syncMargin > 0 ? 1 : 0)
        let pNoisePeak = sigmaSep > 0 ? GlitchRandom.phi(-blankMargin / sigmaSep) : (blankMargin > 0 ? 0 : 1)
        let syncPresent = 1 - min(1, loss * loss * 1.2)

        // Horizontal phase detector.
        var detected: Double? = nil
        let roll = GlitchRandom.uniform(seed, 11, r)
        let pFalse = min(1, 10 * pNoisePeak)
        if roll < pFalse {
            // A noise peak crossed the slice level somewhere in the window.
            detected = (GlitchRandom.uniform(seed, 12, r) - 0.5) * H * 0.6
        } else if GlitchRandom.uniform(seed, 13, r) < pDetect * syncPresent {
            var d = edge - tau
            d += GlitchRandom.gauss(seed, 14, r) * sigmaSep * 0.0125   // edge jitter
            d += humNow * 0.05                                         // hum bend
            detected = d
        }

        // AFC: PI loop around a VCO of limited range, with a sinusoidal
        // phase detector — the Adler-equation behavior of real AFC and
        // injection-locked oscillators. Its restoring force peaks a quarter
        // line off, so past the hold range the loop slips cycles at a beat
        // rate rising from zero as √(detuning): a few slow bars first, more
        // as the hold is turned further.
        var next = theta + H * k.hR + integ
        if let d0 = detected {
            let linear = abs(d0) <= H / 4
            let d = (H / (2 * .pi)) * sin(2 * .pi * d0 / H)
            next += k.kp * d
            // The integral (the frequency correction) only moves on a
            // credible phase reading. While the loop slips cycles the
            // detector sweeps its whole range; integrating that would unwind
            // the correction and turn a slow beat into a sudden shred.
            if linear { integ = min(k.uMax, max(-k.uMax, integ + k.ki * d)) }
        }

        // Vertical sync integrator, fed by the separator's output.
        let duty = raster.syncDuty(ofFieldLine: jf) * syncPresent
        var measured = duty * pDetect + (1 - duty) * pNoisePeak
        let variance = (duty * pDetect * (1 - pDetect)
                        + (1 - duty) * pNoisePeak * (1 - pNoisePeak)) / 60
        if variance > 0 { measured += GlitchRandom.gauss(seed, 15, r) * variance.squareRoot() }
        vInteg += (measured - vInteg) * k.vBeta
        // A vertical sync pulse is the integrator rising through its
        // threshold (with hysteresis, so a noisy crossing counts once).
        var vsync = false
        if vAbove { if vInteg < 0.25 { vAbove = false } }
        else if vInteg >= 0.45 { vAbove = true; vsync = true }

        // Vertical oscillator, phase-locked to those pulses through a
        // sinusoidal detector, as in the sync processors of later sets.
        // Symmetric: detuned either way it holds with a standing phase error
        // (the picture slides, revealing the blanking bar), then past the
        // lock range rolls at a beat rising from zero as √(detuning) — slowly
        // at first. Time advances by exactly one line per line in lock.
        vPhase += 1 + (next - theta) / H
        let period = Double(L) * (1 + k.vTotal)
        if vsync {
            var e = vPhase / period - k.vCenter
            e -= e.rounded()                    // nearest wrap, −½…½
            vPhase -= k.vLock * period * sin(2 * .pi * e)
        }
        if vPhase >= period {
            vPhase -= period
            triggers.append(r)
            if triggers.count > 16 { triggers.removeFirst() }
        }

        // Burst-key loop: a fast first-order follower of the phase error to
        // the nearest sync edge (only when a pulse was seen). Standing and
        // slow errors it tracks out; a slipping loop's error races past it.
        if detected != nil {
            var d = (edge - tau) - gateErr
            d -= H * (d / H).rounded()
            gateErr += k.gateAlpha * d
            gateErr -= H * (gateErr / H).rounded()
        }
        thetaLog[Int(posmod(r, Int64(logCap)))] = theta
        gateLog[Int(posmod(r, Int64(logCap)))] = gateErr
        theta = next
        r += 1
    }

    // MARK: the field to show

    /// The most recently completed field, as the TV drew it.
    public func plan() -> GlitchFieldPlan {
        let k = knobs
        let A = raster.activeLines
        let offset = Int64(raster.vbiLines - nominalTrigger)
        let lastDrawn = r - 1
        let scanStart: Int64 = triggers.last(where: { $0 + offset + Int64(A) - 1 <= lastDrawn })
            ?? (lastDrawn - offset - Int64(A) + 1)
        let first = scanStart + offset

        var rows: [GlitchRow] = []
        rows.reserveCapacity(A)
        for y in 0..<A {
            let tvLine = first + Int64(y)
            let tau = Double(tvLine) * H + loggedTheta(tvLine)
            let (j, u0) = signalLine(at: tau)
            rows.append(GlitchRow(
                u0: Float(u0),
                fieldLine: Int32(posmod(j, Int64(L))),
                lenPrev: Float(H + timebaseError(j) - timebaseError(j - 1)),
                lenCur: Float(H + timebaseError(j + 1) - timebaseError(j)),
                lenNext: Float(H + timebaseError(j + 2) - timebaseError(j + 1)),
                noiseIRE: Float(k.sigma),
                humIRE: Float(hum(atSignalTime: tau)),
                burstScale: Float(burstSurviving(j)),
                gateShift: Float(loggedGate(tvLine))))
        }

        // Settle the color reference over the blanking lines just above
        // the picture. Only blanking and burst can be under the gate there
        // when the set is locked; picture content (torn sets) is treated as
        // no burst — the visible rows then measure the real picture on GPU.
        var chroma = ChromaReference()
        let warm = max(4, Int((12 * raster.scale).rounded()))
        for w in stride(from: warm, to: 0, by: -1) {
            let tvLine = first - Int64(w)
            // The burst gate is blanked during the set's own vertical
            // retrace, so the equalizing and sync lines (no burst) don't
            // drag the color loop off every field.
            if inRetrace(tvLine) { continue }
            let tau = Double(tvLine) * H + loggedTheta(tvLine)
            let (j, u0) = signalLine(at: tau)
            let jf = Int(posmod(j, Int64(L)))
            var gi = 0.0, gq = 0.0
            let g0 = u0 + loggedGate(tvLine)
            if raster.hasBurst(fieldLine: jf) {
                let lo = max(g0 + NTSCTiming.gateStart, NTSCTiming.burstStart)
                let hi = min(g0 + NTSCTiming.gateEnd, NTSCTiming.burstEnd)
                let overlap = max(0, hi - lo) / (NTSCTiming.burstEnd - NTSCTiming.burstStart)
                let amp = NTSCTiming.burstAmplitude * overlap * k.agc * burstSurviving(j)
                gi = amp * NTSCTiming.burstI
                gq = amp * NTSCTiming.burstQ
            }
            let n = noiseSigma(loss: signalLoss(j)) / 92.5 * 0.45
            if n > 0 {
                gi += GlitchRandom.gauss(seed, 21, tvLine) * n
                gq += GlitchRandom.gauss(seed, 22, tvLine) * n
            }
            chroma.step(gi, gq, k: k)
        }

        let topSignalLine = signalLine(at: Double(first) * H + loggedTheta(first)).line
        let signalField = floordiv(topSignalLine, Int64(L))
        return GlitchFieldPlan(
            raster: raster,
            rows: rows,
            vcr: k.vcr ? vcrPlan(field: signalField) : nil,
            chromaPhase: Float(chroma.phase),
            chromaGain: Float(chroma.gain),
            killer: Float(chroma.killer),
            colorOn: chroma.colorOn,
            pictureGain: Float(k.agc),
            ccBits: captionBits(field: signalField),
            fieldIndex: UInt32(truncatingIfNeeded: scanStart),
            settings: k.settings)
    }

    /// Vertical retrace lasts about nine NTSC lines after each trigger.
    private func inRetrace(_ tvLine: Int64) -> Bool {
        let retrace = Int64(max(2, (9 * raster.scale).rounded()))
        return triggers.contains { tvLine >= $0 && tvLine < $0 + retrace }
    }

    private func loggedGate(_ tvLine: Int64) -> Double {
        guard tvLine >= 0, tvLine < r, r - tvLine <= Int64(logCap) else { return gateErr }
        return gateLog[Int(posmod(tvLine, Int64(logCap)))]
    }

    private func loggedTheta(_ tvLine: Int64) -> Double {
        guard tvLine >= 0, tvLine < r, r - tvLine <= Int64(logCap) else { return theta }
        return thetaLog[Int(posmod(tvLine, Int64(logCap)))]
    }

    /// The signal line playing at signal time `tau`, and how far into it.
    private func signalLine(at tau: Double) -> (line: Int64, u: Double) {
        var j = Int64((tau / H).rounded(.down))
        if tau < Double(j) * H + timebaseError(j) { j -= 1 }
        else if tau >= Double(j + 1) * H + timebaseError(j + 1) { j += 1 }
        return (j, tau - (Double(j) * H + timebaseError(j)))
    }

    // MARK: the signal: tape and reception faults per signal line

    private func fieldTime(_ j: Int64) -> Double {
        Double(j) / (Double(L) * NTSCTiming.fieldRate)
    }

    /// Which video head is playing line j. The deck switches heads 6.5
    /// lines before vertical sync.
    private func head(_ j: Int64) -> Int {
        let switchLine = Int64(L) - Int64((3.5 * raster.scale).rounded())
        let f = floordiv(j, Int64(L))
        let jf = posmod(j, Int64(L))
        return Int(posmod(f + (jf >= switchLine ? 1 : 0), 2))
    }

    /// Time-base error of signal line j (µs): when the deck delivers it
    /// against when it should. The heads' placement on the drum (a jump at
    /// each switch), the drum's speed wavering, the tape's motion (servo
    /// error, stick-slip), its stretch against the recording (skew), its
    /// creases — and, on a copy, the same from every deck it was dubbed
    /// through, recorded into it. Zero without the VCR.
    func timebaseError(_ j: Int64) -> Double {
        let k = knobs
        guard k.vcr else { return 0 }
        var e = 0.0
        if k.headSwitch > 0 {
            // Each head has its own timing offset; the jump at each switch
            // is their difference, varying a little field to field.
            let f = floordiv(j + Int64((3.5 * raster.scale).rounded()), Int64(L))
            let wobble = 1 + 0.15 * GlitchRandom.gauss(seed, 31, f)
            e += (head(j) == 0 ? 0.5 : -0.5) * k.headSwitch * wobble
        }
        e += drumFlutter(j, amount: k.transport.flutter, seed: seed)
        e += transport.line(j).tbe
        let read = trackPlace(j, u: 0)
        // Stretched further than when recorded, the tape's lines arrive
        // later the further along the track; the next head starts on its
        // own track's start, and the picture jumps back: skew.
        e += strain(j) * read.along / TapeGeometry.lineLength * H
        if k.tape.creases > 0 {
            // A fold shortens the track: everything after it arrives early.
            for fold in folds(field: read.field) where fold.shortening > 0 {
                let x = (read.along - fold.along) / max(0.05, fold.width)
                let passed = x <= -1 ? 0 : x >= 1 ? 1 : 0.5 + 0.5 * sin(x * .pi / 2)
                e -= fold.shortening / TapeGeometry.writingSpeed * passed
            }
        }
        if k.generations > 0 {
            for g in 1...k.generations { e += dubError(j, generation: g, along: read.along) }
        }
        return e
    }

    /// The tape's stretch against the recording as line j plays. Wrong back
    /// tension isn't steady: the tension arm and its band brake hunt, far
    /// more when the tape is slack (nothing holds the arm against the reel's
    /// wobble) than when it is tight. So the jump at the head switch changes
    /// from field to field, the TV starts each picture a different distance
    /// out, and the top of the picture waves from side to side — the "flag
    /// waving" repair notes give as the sign of low back tension. The share
    /// that wanders (±60% slack, ±15% tight) and its rates are choices.
    ///
    /// Plus what a sticky patch is doing to the tape there (StickyTape).
    private func strain(_ j: Int64) -> Double {
        let tr = knobs.transport
        let sticky = transport.line(j).strain
        guard tr.strain != 0 else { return sticky }
        let t = fieldTime(j)
        let hunt = tr.tension < 0 ? 0.6 : 0.15
        return sticky + tr.strain * (1 + hunt * (0.65 * GlitchRandom.value(seed, 44, t * 2.3)
                                                 + 0.35 * GlitchRandom.value(seed, 45, t * 7.1)))
    }

    /// The drum's speed wavering, as time-base error (µs).
    ///
    /// A drum is a flywheel: its speed can't change from one line to the
    /// next, so the error is smooth — the picture's verticals bow and sway,
    /// they don't go ragged. (Until 0.28 a third of this was noise at 180 Hz
    /// and some of it noise from line to line; a TV follows everything
    /// slower, so that noise was all that showed: every line displaced at
    /// random, which read as a filter, and the same as a sticky tape's.)
    ///
    ///   - once a turn (29.97 Hz), the drum's eccentricity, and the servo
    ///     hunting at a few Hz: the largest parts, and a TV's AFC follows
    ///     nearly all of both;
    ///   - the rest of what repeats every turn — motor cogging, a bearing's
    ///     rough spot, the drum's own lumps — as the 2nd to 12th harmonics
    ///     of the turn, each with its own size (smaller the higher, the odd
    ///     ones smaller still: those differ between the two fields) and a
    ///     phase that drifts over seconds. Tied to the turn, the bends stand
    ///     in the picture instead of changing every field; with a dozen
    ///     unrelated sizes they are this deck's own irregular shape, not a
    ///     sine wave; drifting, the shape crawls and changes;
    ///   - a little rumble, smooth noise up to ~150 Hz: it shimmers.
    ///
    /// The mix and the sizes are choices.
    private func drumFlutter(_ j: Int64, amount: Double, seed: UInt64) -> Double {
        guard amount > 0 else { return 0 }
        let t = fieldTime(j)
        let turnHz = NTSCTiming.fieldRate / 2
        let turn = sin(2 * .pi * turnHz * t + 6.2832 * GlitchRandom.uniform(seed, 40, 0))
        var lumps = 0.0
        for (i, lump) in drumLumps(seed).enumerated() {
            let k = i + 2
            let phase = lump.phase
                + 2.5 * GlitchRandom.value(seed, 50 + UInt64(k), t * (0.4 + 0.1 * Double(k)))
            lumps += lump.size * sin(2 * .pi * Double(k) * turnHz * t + phase)
        }
        return amount * (0.8 * turn + 1.3 * GlitchRandom.value(seed, 41, t * 4)
                         + 0.45 * lumps + 0.15 * GlitchRandom.value(seed, 42, t * 300))
    }

    /// A drum's own shape: the size and resting phase of the 2nd to 12th
    /// harmonics of its turn. Fixed for a deck (this one's, and each earlier
    /// generation's), and asked for on every line, so worked out once.
    private func drumLumps(_ seed: UInt64) -> [(size: Double, phase: Double)] {
        if let known = lumpCache.first(where: { $0.seed == seed }) { return known.lumps }
        var lumps: [(size: Double, phase: Double)] = []
        for k in 2...12 {
            let size = (0.4 + 0.6 * GlitchRandom.uniform(seed, 48, Int64(k))) / pow(Double(k) / 4, 0.8)
                * (k % 2 == 0 ? 1 : 0.35)
            let phase = 6.2832 * GlitchRandom.uniform(seed, 49, Int64(k))
            lumps.append((size, phase))
        }
        lumpCache.append((seed, lumps))
        return lumps
    }

    /// An earlier generation's deck, recorded into this copy: its heads'
    /// switching jump, its drum's flutter and a little skew — a good deck,
    /// but no two are alike.
    private func dubError(_ j: Int64, generation g: Int, along: Double) -> Double {
        let s = GlitchRandom.mix(seed ^ UInt64(g) &* 0x9E37_79B9)
        let f = floordiv(j + Int64((3.5 * raster.scale).rounded()), Int64(L))
        let jump = (0.4 + 0.8 * GlitchRandom.uniform(s, 1, 0)) * (posmod(f + Int64(g), 2) == 0 ? 0.5 : -0.5)
        let strain = 3e-4 * 0.2 * (2 * GlitchRandom.uniform(s, 2, 0) - 1)
        return jump + strain * along / TapeGeometry.lineLength * H + drumFlutter(j, amount: 0.12, seed: s)
    }

    /// Where line j's start is read: which field's track, how far along it.
    /// The lines after the head switch are read by the other head from the
    /// start of the next track (each track is recorded a little longer than
    /// its field, so the heads overlap there).
    private func trackPlace(_ j: Int64, u: Double) -> (field: Int64, along: Double) {
        let f = floordiv(j, Int64(L))
        let jf = posmod(j, Int64(L))
        let switched = jf >= switchLine
        let lineInTrack = Double(switched ? jf - Int64(L) : jf)
        return (f + (switched ? 1 : 0),
                TapeGeometry.alongTrack(fieldLine: lineInTrack, u: u, linesPerField: L))
    }

    private var switchLine: Int64 { Int64(L) - Int64((3.5 * raster.scale).rounded()) }

    private func folds(field f: Int64) -> [TapeSurface.Fold] {
        if let c = foldCache.first(where: { $0.field == f }) { return c.folds }
        let list = TapeSurface.folds(field: f, knobs.tape, format: knobs.transport.format)
        foldCache.append((f, list))
        if foldCache.count > 8 { foldCache.removeFirst() }
        return list
    }

    /// How far line j's head is off its own track's center, `along` mm up
    /// track `g` (track pitches; ±1 is the neighboring track): the tape out
    /// of place (servo, tracking control, stick-slip), the track bent
    /// against the heads' path (recorded on another deck), stretch turning
    /// it, and picture search sweeping across.
    private func headDelta(_ j: Int64, along: Double, track g: Int64) -> Double {
        let k = knobs
        var d = transport.line(j).delta + trackShape(along)
        d += strain(j) * along * cos(TapeGeometry.angle) / k.transport.format.advancePerField
        if k.transport.searching {
            let s = transport.search(field: g)
            d += s.phase + s.rate * along / TapeGeometry.trackLength
        }
        return d
    }

    /// The recorded track against the heads' path (pitches): no two decks'
    /// tape guides are set alike, so a track bends and leans a few µm away
    /// from where this deck's heads sweep — the same µm being more of a
    /// narrow LP or EP track.
    private func trackShape(_ along: Double) -> Double {
        let ts = UInt64(knobs.tape.seed)
        let lean = 4 * (2 * GlitchRandom.uniform(ts, 91, 0) - 1)
        let bow = 2.5 * (2 * GlitchRandom.uniform(ts, 92, 0) - 1)
        let x = 2 * along / TapeGeometry.trackLength - 1
        return (lean * x + bow * (1 - x * x)) / (knobs.transport.format.trackPitch * 1000)
    }

    /// Spacing a slack tape adds where it doesn't hug the drum, at the two
    /// ends of the heads' sweep (µm).
    ///
    /// Up to tension −1 the lift grows (0.6 µm there: the start of the
    /// sweep, where vertical sync is read, sits just above the FM threshold
    /// on a good tape). Slacker than that it grows very little more — or
    /// every slack tape would lose vertical hold and roll, which is the
    /// Vertical hold knob's look, not this one's — and instead reaches
    /// further into the sweep: the top of the picture sinks into noise
    /// over a taller and taller band. Both are choices.
    private func slackSpacing(_ along: Double) -> Double {
        let slack = max(0, -knobs.transport.tension)
        guard slack > 0 else { return 0 }
        // The tape lifts most where it wraps onto the drum — the start of
        // the sweep, the top of the picture — and a little where it leaves.
        let L = TapeGeometry.trackLength
        let more = max(0, slack - 1)
        let reach = 22 * (1 + 0.5 * more)
        let end = Double(max(TapeSurface.smoothstep(Float(reach), 0, Float(along)),
                             0.6 * TapeSurface.smoothstep(Float(L - 10 - 5 * more), Float(L), Float(along))))
        return (0.6 * min(1, slack) + 0.02 * more) * end
    }

    /// What the playing head sees at line j, u µs in, at `mhz`: the carrier
    /// it reads off tracks of its own azimuth, and the crosstalk off the
    /// others — through the tape there, the head's own condition, and how
    /// it sits across the tracks.
    func carrier(_ j: Int64, u: Double, mhz: Double, flakes: Bool = true) -> (own: Double, crosstalk: Double) {
        let read = trackPlace(j, u: u)
        let h = head(j)
        let heads = deck.heads(forField: read.field)
        let dk = knobs.deck
        let fmt = knobs.transport.format
        let delta = headDelta(j, along: read.along, track: read.field)
        let p = TapeSurface.at(TapeGeometry.point(field: read.field, along: read.along,
                                                  across: -delta * fmt.trackPitch, format: fmt),
                               knobs.tape, detail: false, flakes: flakes)
        let d = Double(p.lift + dk.wearSpacing(h, field: read.field, along: read.along, seed: knobs.tape.seed)
                       + dk.baselineDirt(h, seed: knobs.tape.seed, field: read.field)
                       + heads[h].debris + max(p.film, heads[h].grease)) + slackSpacing(read.along)
        var a = Double(p.output * dk.efficiency(h)) * VcrChannel.channelGain(mhz: mhz, spacing: d, gap: Double(dk.gap(h)))
        if mhz < 1 { a *= Double(dk.colorBoost(h, tape: knobs.tape)) }
        let r = fmt.read(delta: delta)
        let shares = mhz < 1 ? r.color : r.fm
        var own = 0.0, cross = 0.0
        for t in 0..<3 {
            if (r.center - 1 + t) % 2 == 0 { own += shares[t] } else { cross += abs(shares[t]) }
        }
        return (a * own, a * cross)
    }

    /// Fraction of line j's sync lost to the tape: the FM carrier at the
    /// sync tip against the deck's noise. Above the FM threshold (~11 dB)
    /// demodulated sync stays clean; below it, it drowns in clicks.
    ///
    /// The neighbors' crosstalk is another FM carrier, not noise: the
    /// limiter and demodulator ride over a weaker one (the capture effect),
    /// and it only brings the threshold closer where it beats against the
    /// carrier, its envelope dipping to own − crosstalk. (Counted as noise
    /// power, the few µm of neighbor an EP head always reads held a clean EP
    /// tape 4 dB above threshold, against SP's 23.)
    ///
    /// A flake over the sync pulse doesn't cost it while the deck's dropout
    /// compensation is on: what the compensator replays from its one-line
    /// delay is the line before, sync pulse and all. (Without that, every
    /// flaw kicked the TV's horizontal lock, and Oxide flaws read as bands
    /// of torn picture, not as dropouts.) Anything longer — mold, a crease,
    /// a clog — outlasts it.
    func signalLoss(_ j: Int64) -> Double {
        guard knobs.vcr else { return 0 }
        let c = carrier(j, u: 2.0, mhz: VcrChannel.syncTipMHz, flakes: !knobs.dropoutCompensation)
        let noise = pow(10, -VcrChannel.carrierToNoiseDB / 10) * pow(knobs.transport.format.noiseScale, 2)
        let envelope = max(0, c.own - c.crosstalk)
        let cnr = 10 * log10(max(1e-12, envelope * envelope) / noise)
        let x = min(1, max(0, (11 - cnr) / 9))
        return x * x
    }

    /// The share of line j's color burst the deck passes on: its color
    /// killer cuts out when the color-under carrier is lost (about 30 dB
    /// down), and keeps the burst up (ACC) until then. Crosstalk from the
    /// other azimuth's tracks the comb filter cancels. A flake over the
    /// burst is a dropout, which the deck's ACC holds through (vcr_acc):
    /// left in, every big flake turned a line's color up or off.
    private func burstSurviving(_ j: Int64) -> Double {
        guard knobs.vcr else { return 1 }
        let a = carrier(j, u: 6.5, mhz: VcrChannel.colorUnderMHz, flakes: false).own
        let db = 20 * log10(max(1e-6, a))
        let t = min(1, max(0, (db + 34) / 8))
        return t * t * (3 - 2 * t)
    }

    /// The displayed field's active lines as the VCR reads them — and, on a
    /// copy, as each deck before read the tapes it was dubbed from.
    private func vcrPlan(field f: Int64) -> VcrFieldPlan {
        let k = knobs
        let fmt = k.transport.format
        var lines: [VcrLine] = []
        lines.reserveCapacity(raster.activeLines)
        for y in 0..<raster.activeLines {
            let j = f * Int64(L) + Int64(raster.vbiLines + y)
            let read = trackPlace(j, u: 0)
            let h = head(j)
            let heads = deck.heads(forField: read.field)
            let origin = TapePosition(x: TapeGeometry.trackOrigin(field: read.field, format: fmt), y: 0)
            let d0 = headDelta(j, along: read.along, track: read.field)
            let d1 = headDelta(j, along: read.along + 1, track: read.field)
            lines.append(VcrLine(
                originBase: origin.base, originOffset: origin.offset, along0: Float(read.along),
                spacing: k.deck.wearSpacing(h, field: read.field, along: read.along, seed: k.tape.seed)
                    + k.deck.baselineDirt(h, seed: k.tape.seed, field: read.field) + heads[h].debris
                    + Float(slackSpacing(read.along)),
                grease: heads[h].grease,
                gain: k.deck.efficiency(h),
                head: UInt32(h),
                delta0: Float(d0), deltaSlope: Float(d1 - d0),
                colorBoost: k.deck.colorBoost(h, tape: k.tape), colorNoise: k.deck.colorNoise(h)))
        }
        var plan = VcrFieldPlan(lines: lines, tape: k.tape, deck: k.deck, format: fmt)
        if k.generations > 0 {
            plan.earlier = (1...k.generations).map { dubPlan(field: f, generation: $0) }
            plan.linked = true
            plan.ycMismatch = ycMismatch(generation: k.generations + 1)
        }
        return plan
    }

    /// How far generation g's recording deck's picture delay misses its
    /// color delay (samples, ±100 ns).
    private func ycMismatch(generation g: Int) -> Int {
        let s = GlitchRandom.mix(seed ^ UInt64(g) &* 0x9E37_79B9)
        return Int((6 * GlitchRandom.uniform(s, 3, 0) - 3).rounded())
    }

    /// Generation g of the copies this tape was dubbed through (1 is the
    /// first recording; later ones were recorded from the one before's
    /// playback): a decent tape in a decent deck, at this tape's speed.
    private func dubPlan(field f: Int64, generation g: Int) -> VcrFieldPlan {
        let settings = GlitchSettings(values: [
            "tape_seed": Double(knobs.settings["tape_seed"].rounded()) + Double(1000 * g),
            "tape_wear": asBefore("tape_wear", 0.1), "tape_dropouts": asBefore("tape_dropouts", 0.05), "head_wear": 0.1])
        let tape = TapeParams(settings), deck = DeckParams(settings)
        let fmt = knobs.transport.format
        var lines: [VcrLine] = []
        lines.reserveCapacity(raster.activeLines)
        for y in 0..<raster.activeLines {
            let j = f * Int64(L) + Int64(raster.vbiLines + y)
            let read = trackPlace(j, u: 0)
            let h = Int(posmod(Int64(head(j) + g), 2))
            let origin = TapePosition(x: TapeGeometry.trackOrigin(field: read.field, format: fmt), y: 0)
            lines.append(VcrLine(
                originBase: origin.base, originOffset: origin.offset, along0: Float(read.along),
                spacing: deck.wearSpacing(h), grease: 0, gain: deck.efficiency(h), head: UInt32(h),
                delta0: 0, deltaSlope: 0))
        }
        var plan = VcrFieldPlan(lines: lines, tape: tape, deck: deck, format: fmt)
        plan.linked = g > 1
        plan.ycMismatch = ycMismatch(generation: g)
        return plan
    }

    private func noiseSigma(loss: Double) -> Double {
        let tape = loss * 90
        return (knobs.sigma * knobs.sigma + tape * tape).squareRoot()
    }

    private func hum(atSignalTime tau: Double) -> Double {
        guard knobs.humIRE > 0 else { return 0 }
        let t = tau / usPerSecond
        return knobs.humIRE * (0.8 * sin(2 * .pi * 60 * t)
                               + 0.3 * sin(2 * .pi * 120 * t + 0.7))
    }

    /// Line 21: clock run-in start bits (0, 0, 1) then two 7-bit characters
    /// with odd parity, LSB first — 19 bits.
    private func captionBits(field f: Int64) -> UInt32 {
        guard knobs.captions else { return 0 }
        func char(_ i: Int64) -> UInt32 {
            let c = UInt32(0x20 + Int(GlitchRandom.uniform(seed, 71, f, i) * 90))
            let parity: UInt32 = c.nonzeroBitCount % 2 == 0 ? 0x80 : 0
            return c | parity
        }
        return 0b100 | (char(0) << 3) | (char(1) << 11)
    }

    // MARK: calibration

    private static func calibrate(raster: ReceiverRaster, seed: UInt64) -> Int {
        let sim = ReceiverSimulator(uncalibrated: raster, seed: seed)
        sim.advance(to: 0, settings: GlitchSettings())
        guard let t = sim.triggers.last else { return raster.preEqEnd + 2 }
        return Int(posmod(t, Int64(raster.totalLines)))
    }

    private init(uncalibrated raster: ReceiverRaster, seed: UInt64) {
        self.raster = raster
        self.seed = seed
        L = raster.totalLines
        usPerSecond = NTSCTiming.line * Double(raster.totalLines) * NTSCTiming.fieldRate
        logCap = 4 * raster.totalLines + 64
        thetaLog = Array(repeating: 0, count: logCap)
        gateLog = Array(repeating: 0, count: logCap)
        knobs = Knobs(GlitchSettings(), raster: raster)
        transport = TransportSimulator(linesPerField: raster.totalLines, seed: seed, settings: GlitchSettings())
        nominalTrigger = 0
    }
}

// MARK: - knobs → circuit constants

struct Knobs {
    let settings: GlitchSettings
    /// RF noise, IRE RMS. Signal strength maps linearly to a carrier-to-
    /// noise ratio of 0–60 dB: snow shows below ~45 dB, color fails below
    /// ~20, sync below ~12, as on real sets.
    let sigma: Double
    /// Picture amplitude once the AGC runs out of gain (very weak signals).
    let agc: Double
    /// Vertical oscillator's free-running detuning (fraction of a field).
    let vTotal: Double
    /// Its greatest pull per detected pulse, as a fraction of the field —
    /// which is also the lock range: 1.5%, beyond which the picture rolls.
    let vLock = 0.015
    /// The set is aligned so that, at its centered hold, retrace starts at the
    /// vertical sync pulse despite the oscillator's built-in detuning — the
    /// standing phase error that detuning would cause, canceled.
    let vCenter: Double
    let vBeta: Double
    /// Horizontal oscillator's free-running offset per raster line.
    let hR: Double
    let kp: Double
    let ki: Double
    let uMax: Double
    let humIRE: Double
    /// The VCR is playing; the deck and tape knobs below only matter then.
    let vcr: Bool
    let tape: TapeParams
    let deck: DeckParams
    let transport: TransportParams
    /// Copies the tape was dubbed through before this one (0: the original).
    let generations: Int
    let headSwitch: Double
    /// The deck's dropout compensator is on.
    let dropoutCompensation: Bool
    let captions: Bool
    /// Burst-key loop rate per raster line (~6 NTSC lines).
    let gateAlpha: Double
    // Color reference loop rates, per raster line.
    let chromaAlpha: Double
    let accGamma: Double
    let killerKappa: Double

    init(_ settings: GlitchSettings, raster: ReceiverRaster) {
        self.settings = settings
        let s = raster.scale
        let strength = min(1, max(0, settings["signal_strength"]))
        // Carrier-to-noise ratio falls linearly from 38 dB to 0 across the
        // knob, so every part of its travel does something: faint snow just
        // below 100%, heavy by 50%, color and sync failing below ~30%,
        // nothing but snow at 0. The last term takes the residual noise at
        // 100% to exactly zero.
        sigma = max(0, 100 * pow(10, -1.9 * strength) - 1.26 * pow(strength, 4))
        agc = min(1, strength / 0.45)
        // Knob → detuning on a power curve, so the travel spreads over the
        // range where things happen: the picture slides from the first few
        // percent, rolls from ~25%, ~6 rolls a second at the end. A small
        // built-in detuning (as no real oscillator is exact) makes a
        // signal that loses its sync drift slowly instead of holding still.
        let vKnob = settings["vertical_hold"]
        let builtIn = 0.002
        vTotal = builtIn + (vKnob < 0 ? -1 : 1) * 0.10 * pow(abs(vKnob), 1.37)
        vCenter = asin(builtIn / vLock) / (2 * .pi)
        vBeta = 1 - exp(-1 / (1.5 * s))
        // Horizontal: the AFC is proportional, so any detuning shows as a
        // standing phase error — the picture slides. The knob curve is in two
        // parts: up to the hold-in edge (~35%) the slide grows gently (under
        // 2 µs to ~15%; the burst gate slides off the burst — color drops
        // out — around 20%); past it, cycle slipping starts with one or two
        // slow bars and builds to ~11.
        let hKnob = abs(settings["horizontal_hold"])
        let kpN = 0.04 * pow(10, min(1, max(0, settings["afc_speed"])))
        let edge = 0.04 * pow(10, 0.5) / (2 * .pi)        // hold-in edge at the default AFC
        let hFree = hKnob <= 0.35
            ? edge * pow(hKnob / 0.35, 2)
            : edge + 0.0265 * (hKnob - 0.35) / 0.65
        hR = (settings["horizontal_hold"] < 0 ? -1 : 1) * hFree / s
        // AFC: proportional gain 0.04–0.4 per NTSC line.
        kp = kpN / s
        ki = pow(kpN / 1.4, 2) / (s * s)
        uMax = 0
        humIRE = settings["hum"] * 60
        vcr = settings.vcr
        tape = TapeParams(settings)
        deck = DeckParams(settings)
        transport = TransportParams(settings)
        generations = min(3, max(0, Int(settings["tape_generation"].rounded())))
        headSwitch = settings["head_switch"]
        dropoutCompensation = settings.flag("dropout_compensation")
        captions = settings.flag("closed_captions")
        gateAlpha = 1 - exp(-1 / (6 * s))
        chromaAlpha = 1 - exp(-1 / (4 * s))
        accGamma = 1 - exp(-1 / (8 * s))
        killerKappa = 1 - exp(-1 / (15 * s))
    }
}

/// The TV's color reference: a 3.58 MHz oscillator phase-locked to the
/// burst seen through the burst gate, an ACC amplifier normalizing chroma to
/// the burst's amplitude, and a color killer that switches chroma off when
/// no burst is found. The same recurrence runs on the GPU for visible rows.
struct ChromaReference {
    var phase = 0.0
    var gain = 1.0
    var killer = 1.0
    var colorOn = true

    mutating func step(_ gi: Double, _ gq: Double, k: Knobs) {
        let b0 = NTSCTiming.burstAmplitude
        let mag = (gi * gi + gq * gq).squareRoot()
        // Rotate the measurement into the reference frame.
        let c = cos(-phase), s = sin(-phase)
        let ri = gi * c - gq * s
        let rq = gi * s + gq * c
        let dot = ri * NTSCTiming.burstI + rq * NTSCTiming.burstQ
        let cross = NTSCTiming.burstI * rq - NTSCTiming.burstQ * ri
        if mag > 0 {
            phase += k.chromaAlpha * min(1, mag / b0) * atan2(cross, dot)
        }
        let c2 = cos(-phase), s2 = sin(-phase)
        let inPhase = (gi * c2 - gq * s2) * NTSCTiming.burstI + (gi * s2 + gq * c2) * NTSCTiming.burstQ
        gain += k.accGamma * (b0 / max(inPhase, 0.25 * b0) - gain)
        gain = min(3, max(0.3, gain))
        killer += k.killerKappa * (min(1, max(-1, inPhase / b0)) - killer)
        if colorOn, killer < 0.3 { colorOn = false }
        else if !colorOn, killer > 0.5 { colorOn = true }
    }
}

@inline(__always)
func posmod(_ a: Int64, _ m: Int64) -> Int64 {
    let r = a % m
    return r < 0 ? r + m : r
}

@inline(__always)
func floordiv(_ a: Int64, _ m: Int64) -> Int64 {
    a >= 0 ? a / m : -((-a + m - 1) / m)
}
