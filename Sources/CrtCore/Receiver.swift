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
    public static let activeStart = 9.4
    public static let activeLength = 52.656
    public static var activeEnd: Double { activeStart + activeLength }
    public static let equalizingPulse = 2.3
    public static let broadPulse = 27.1
    public static let fieldRate = 60000.0 / 1001.0          // 59.94 Hz (colour)
    public static let linesPerField = 262.5
    public static let subcarrierMHz = 315.0 / 88.0          // 3.579545
    /// Colour burst direction in the decoder's I/Q plane: 180° on the B−Y
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
/// started relative to the signal. Mirrors the GPU struct (8 × 4 bytes).
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
    /// Noise on this line, IRE RMS.
    public var noiseIRE: Float
    /// Mains hum on this line, IRE.
    public var humIRE: Float
    /// Fraction of the burst surviving tape signal loss.
    public var burstScale: Float
}

/// Lost stretch of a signal line (oxide dropout). Mirrors the GPU struct.
public struct GlitchDropout: Equatable {
    public var fieldLine: Int32
    public var uStart: Float
    public var uLength: Float
    public var pad: Float = 0
}

/// Everything the GPU stage needs for one displayed field.
public struct GlitchFieldPlan {
    public var raster: ReceiverRaster
    public var rows: [GlitchRow]
    public var dropouts: [GlitchDropout]
    /// Colour reference state entering the first visible row: the phase
    /// error of the TV's 3.58 MHz oscillator (rad), the ACC gain, the
    /// colour killer's integrator and its on/off state.
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
    // Vertical oscillator.
    private var ramp = 0.0
    private var vInteg = 0.0
    private var triggers: [Int64] = []
    // Recent TV line starts, for building the displayed field.
    private var thetaLog: [Double]
    private let logCap: Int

    private var knobs: Knobs
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
        knobs = Knobs(GlitchSettings(), raster: raster)
        nominalTrigger = Self.calibrate(raster: raster, seed: seed)
        reset()
    }

    /// Back to a freshly started set, `warmup` seconds before time zero.
    public func reset() {
        r = 0
        theta = 0
        integ = 0
        ramp = 0
        vInteg = 0
        triggers.removeAll()
        for i in thetaLog.indices { thetaLog[i] = 0 }
    }

    /// Run the set forward to `time` with `settings` in force since the
    /// previous call.
    public func advance(to time: Double, settings: GlitchSettings) {
        knobs = Knobs(settings, raster: raster)
        let target = (time + Self.warmup) * usPerSecond
        while Double(r) * H + theta <= target { step() }
    }

    /// Simulate from a fresh start to `time`, with settings that may vary:
    /// `settingsAt` is sampled once per `frameDuration` exactly as a frame-
    /// by-frame advance would, so the result matches one bit for bit.
    public func resimulate(to time: Double, frameDuration: Double,
                           settingsAt: (Double) -> GlitchSettings) {
        reset()
        let first = settingsAt(0)
        advance(to: 0, settings: first)
        guard time > 0, frameDuration > 0 else { return }
        var k = 1
        while true {
            let t = min(time, Double(k) * frameDuration)
            advance(to: t, settings: settingsAt(t))
            if t >= time { break }
            k += 1
        }
    }

    // MARK: one scan line

    private func step() {
        let k = knobs
        let tau = Double(r) * H + theta

        // The signal line whose sync edge is nearest the TV's line start.
        var j = Int64((tau / H).rounded())
        var e = timebaseError(j)
        var edge = Double(j) * H + e
        if tau - edge > H / 2 { j += 1; e = timebaseError(j); edge = Double(j) * H + e }
        else if edge - tau > H / 2 { j -= 1; e = timebaseError(j); edge = Double(j) * H + e }
        let jf = Int(posmod(j, Int64(L)))
        let loss = signalLoss(j)
        let sigma = noiseSigma(loss: loss)
        // The separator slices halfway down the 40 IRE sync pulse, after
        // a ~0.5 MHz low-pass that keeps about a third of the video noise.
        let sigmaSep = sigma * 0.35
        let pDetect = sigmaSep > 0 ? GlitchRandom.phi(20 / sigmaSep) : 1
        let pNoisePeak = sigmaSep > 0 ? GlitchRandom.phi(-20 / sigmaSep) : 0
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
            d += hum(atSignalTime: tau) * 0.03                         // hum bend
            detected = d
        }

        // AFC: PI loop around a VCO of limited range. The detector's
        // restoring force peaks a quarter line off and falls beyond it, so
        // a strained loop slips cycles rather than holding indefinitely.
        var next = theta + H * k.hR + integ
        if let d0 = detected {
            var d = d0
            if d > H / 4 { d = H / 2 - d } else if d < -H / 4 { d = -H / 2 - d }
            next += k.kp * d
            integ = min(k.uMax, max(-k.uMax, integ + k.ki * d))
        }

        // Vertical sync integrator, fed by the separator's output.
        let duty = raster.syncDuty(ofFieldLine: jf) * syncPresent
        var measured = duty * pDetect + (1 - duty) * pNoisePeak
        let variance = (duty * pDetect * (1 - pDetect)
                        + (1 - duty) * pNoisePeak * (1 - pNoisePeak)) / 60
        if variance > 0 { measured += GlitchRandom.gauss(seed, 15, r) * variance.squareRoot() }
        vInteg += (measured - vInteg) * k.vBeta

        // Vertical oscillator: a ramp the integrated sync can trigger early.
        let lineTime = (Double(r + 1) * H + next) - tau
        ramp += lineTime / (H * Double(L) * (1 + k.vTotal))
        if ramp >= 0.5 && ramp + k.vGain * vInteg >= 1 {
            ramp = 0
            triggers.append(r)
            if triggers.count > 16 { triggers.removeFirst() }
        }

        thetaLog[Int(posmod(r, Int64(logCap)))] = theta
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
            let loss = signalLoss(j)
            rows.append(GlitchRow(
                u0: Float(u0),
                fieldLine: Int32(posmod(j, Int64(L))),
                lenPrev: Float(H + timebaseError(j) - timebaseError(j - 1)),
                lenCur: Float(H + timebaseError(j + 1) - timebaseError(j)),
                lenNext: Float(H + timebaseError(j + 2) - timebaseError(j + 1)),
                noiseIRE: Float(noiseSigma(loss: loss)),
                humIRE: Float(hum(atSignalTime: tau)),
                burstScale: Float(max(0, 1 - loss))))
        }

        // Settle the colour reference over the blanking lines just above
        // the picture. Only blanking and burst can be under the gate there
        // when the set is locked; picture content (torn sets) is treated as
        // no burst — the visible rows then measure the real picture on GPU.
        var chroma = ChromaReference()
        let warm = max(4, Int((12 * raster.scale).rounded()))
        for w in stride(from: warm, to: 0, by: -1) {
            let tvLine = first - Int64(w)
            // The burst gate is blanked during the set's own vertical
            // retrace, so the equalizing and sync lines (no burst) don't
            // drag the colour loop off every field.
            if inRetrace(tvLine) { continue }
            let tau = Double(tvLine) * H + loggedTheta(tvLine)
            let (j, u0) = signalLine(at: tau)
            let jf = Int(posmod(j, Int64(L)))
            var gi = 0.0, gq = 0.0
            if raster.hasBurst(fieldLine: jf) {
                let lo = max(u0 + NTSCTiming.burstStart, NTSCTiming.burstStart)
                let hi = min(u0 + NTSCTiming.burstEnd, NTSCTiming.burstEnd)
                let overlap = max(0, hi - lo) / (NTSCTiming.burstEnd - NTSCTiming.burstStart)
                let amp = NTSCTiming.burstAmplitude * overlap * k.agc * max(0, 1 - signalLoss(j))
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
            dropouts: dropouts(inField: signalField),
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

    /// Time-base error of signal line j (µs): head switching, flutter,
    /// crinkle. Zero for a clean signal.
    func timebaseError(_ j: Int64) -> Double {
        let k = knobs
        var e = 0.0
        if k.headSwitch > 0 {
            // Each head has its own timing offset; the jump at each switch
            // is their difference, varying a little field to field.
            let f = floordiv(j + Int64((3.5 * raster.scale).rounded()), Int64(L))
            let wobble = 1 + 0.15 * GlitchRandom.gauss(seed, 31, f)
            e += (head(j) == 0 ? 0.5 : -0.5) * k.headSwitch * wobble
        }
        if k.jitter > 0 {
            let lineScale = 1 / raster.scale
            let slow = GlitchRandom.value(seed, 32, Double(j) * lineScale / 40)
            let fast = GlitchRandom.gauss(seed, 33, j) * 0.35
            e += k.jitter * (slow + fast)
        }
        if k.crinkle > 0 {
            let c = crinkleAt(j)
            if c.intensity > 0 {
                let lineScale = 1 / raster.scale
                e += c.intensity * 4.0 * GlitchRandom.value(seed, 34, Double(j) * lineScale / 3)
                e += c.envelope * 1.5 * GlitchRandom.value(seed, 35, Double(j) * lineScale / 60)
            }
        }
        return e
    }

    /// Fraction of the RF signal lost on line j (tape faults).
    func signalLoss(_ j: Int64) -> Double {
        let k = knobs
        var loss = 0.0
        if k.clog > 0 {
            // Debris on the heads comes and goes: each field is lost with a
            // probability that grows with the clog, and the rest of the
            // fields are dulled.
            let f = floordiv(j, Int64(L))
            let dropped = GlitchRandom.uniform(seed, 41, f) < k.clog * 0.8
            let level = dropped ? 0.85 + 0.15 * GlitchRandom.uniform(seed, 42, f) : 0.35 * k.clog * k.clog
            loss = max(loss, min(1, level))
        }
        if k.crinkle > 0 { loss = max(loss, crinkleAt(j).intensity) }
        return loss
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

    /// Crinkle events: creased stretches of tape crossing the heads, as a
    /// moving band of signal loss plus a disturbance to the transport.
    private func crinkleAt(_ j: Int64) -> (intensity: Double, envelope: Double) {
        let t = fieldTime(j)
        let slot = 0.5
        let p = knobs.crinkle * 0.6
        let s = Int64((t / slot).rounded(.down))
        var best = (intensity: 0.0, envelope: 0.0)
        for k in (s - 1)...s {
            guard GlitchRandom.uniform(seed, 51, k) < p else { continue }
            let start = Double(k) * slot + GlitchRandom.uniform(seed, 52, k) * slot
            let duration = 0.12 + 0.35 * GlitchRandom.uniform(seed, 53, k)
            guard t >= start, t < start + duration else { continue }
            let severity = 0.55 + 0.45 * GlitchRandom.uniform(seed, 54, k)
            let progress = (t - start) / duration
            let envelope = sin(.pi * progress)
            let pos = Double(posmod(j, Int64(L))) / Double(L)
            let speed = 0.8 + 1.6 * GlitchRandom.uniform(seed, 55, k)
            let center = (GlitchRandom.uniform(seed, 56, k) + progress * speed)
                .truncatingRemainder(dividingBy: 1)
            var d = abs(pos - center)
            d = min(d, 1 - d)
            let width = 0.05 + 0.08 * severity
            let band = max(0, 1 - d / width)
            let intensity = min(1, severity * envelope * band * 1.4)
            if intensity > best.intensity { best = (intensity, envelope) }
            else if envelope > best.envelope { best.envelope = envelope }
        }
        return best
    }

    private func dropouts(inField f: Int64) -> [GlitchDropout] {
        let rate = knobs.dropouts
        guard rate > 0 else { return [] }
        let mean = rate * rate * 14
        let n = max(0, min(64, Int((mean + mean.squareRoot()
                                    * GlitchRandom.gauss(seed, 61, f)).rounded())))
        var out: [GlitchDropout] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let line = raster.vbiLines
                + Int(GlitchRandom.uniform(seed, 62, f, Int64(i)) * Double(raster.activeLines))
            let start = NTSCTiming.activeStart
                + GlitchRandom.uniform(seed, 63, f, Int64(i)) * NTSCTiming.activeLength * 0.95
            let length = min(30, max(0.4, -log(max(1e-6, GlitchRandom.uniform(seed, 64, f, Int64(i))))
                                     * (1.5 + 5 * rate)))
            out.append(GlitchDropout(fieldLine: Int32(min(line, raster.totalLines - 1)),
                                     uStart: Float(start), uLength: Float(length)))
        }
        return out
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
        knobs = Knobs(GlitchSettings(), raster: raster)
        nominalTrigger = 0
    }
}

// MARK: - knobs → circuit constants

struct Knobs {
    let settings: GlitchSettings
    /// RF noise, IRE RMS. Signal strength maps linearly to a carrier-to-
    /// noise ratio of 0–60 dB: snow shows below ~45 dB, colour fails below
    /// ~20, sync below ~12, as on real sets.
    let sigma: Double
    /// Picture amplitude once the AGC runs out of gain (very weak signals).
    let agc: Double
    /// Vertical oscillator's free-running period, as a fraction of a field
    /// slower than the signal. Lock holds from ~0.4% to ~4%.
    let vTotal: Double
    let vGain = 0.055
    let vBeta: Double
    /// Horizontal oscillator's free-running offset per raster line.
    let hR: Double
    let kp: Double
    let ki: Double
    let uMax: Double
    let humIRE: Double
    let headSwitch: Double
    let jitter: Double
    let crinkle: Double
    let clog: Double
    let dropouts: Double
    let captions: Bool
    // Colour reference loop rates, per raster line.
    let chromaAlpha: Double
    let accGamma: Double
    let killerKappa: Double

    init(_ settings: GlitchSettings, raster: ReceiverRaster) {
        self.settings = settings
        let s = raster.scale
        let strength = min(1, max(0, settings["signal_strength"]))
        let cnr = 60 * strength
        sigma = max(0, 100 * pow(10, -cnr / 20) - 0.1)
        agc = min(1, strength / 0.35)
        vTotal = 0.023 + settings["vertical_hold"] * 0.12
        vBeta = 1 - exp(-1 / (1.5 * s))
        hR = settings["horizontal_hold"] * 0.10 / s
        // AFC: proportional gain 0.04–0.4 per NTSC line, damping 0.7.
        let kpN = 0.04 * pow(10, min(1, max(0, settings["afc_speed"])))
        kp = kpN / s
        ki = pow(kpN / 1.4, 2) / (s * s)
        uMax = 0.025 * NTSCTiming.line / s
        humIRE = settings["hum"] * 25
        headSwitch = settings["head_switch"]
        jitter = settings["timebase_jitter"]
        crinkle = settings["crinkle"]
        clog = settings["head_clog"]
        dropouts = settings["dropouts"]
        captions = settings.flag("closed_captions")
        chromaAlpha = 1 - exp(-1 / (4 * s))
        accGamma = 1 - exp(-1 / (8 * s))
        killerKappa = 1 - exp(-1 / (15 * s))
    }
}

/// The TV's colour reference: a 3.58 MHz oscillator phase-locked to the
/// burst seen through the burst gate, an ACC amplifier normalizing chroma to
/// the burst's amplitude, and a colour killer that switches chroma off when
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
