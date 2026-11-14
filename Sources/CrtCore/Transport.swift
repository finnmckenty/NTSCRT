import Foundation

/// The deck's transport as the simulation uses it, from the knobs: how the
/// tape is moved past the drum, which decides where the heads' sweep falls
/// on the recorded tracks and when the signal on them arrives.
public struct TransportParams: Equatable {
    /// Back tension against the recording deck's, −1…1.
    public var tension: Double
    /// Worn drum motor, belts and pinch roller, 0…1.
    public var flutter: Double
    /// The tracking control: where the servo puts the tape, in track
    /// pitches (±1 is a whole track).
    public var tracking: Double
    /// Picture search multiple (1 = normal play).
    public var search: Double
    public var format: TapeFormat

    public init(_ s: GlitchSettings) {
        tension = min(1, max(-1, s["back_tension"]))
        flutter = min(1, max(0, s["transport_flutter"]))
        // The knob on a curve: its first half moves the heads three
        // quarters of the way off their tracks (the picture just gets
        // noisier); the rest is where noise bands break out and take over.
        let k = min(1, max(-1, s["tracking_offset"]))
        tracking = (k < 0 ? -1 : 1) * (1 - (1 - abs(k)) * (1 - abs(k)))
        search = min(9, max(1, s["search_speed"]))
        format = TapeFormat(s)
    }

    /// How much longer the tape is stretched than when it was recorded: the
    /// strain of ~0.3 N more tension on a VHS tape's 0.24 mm² of PET at the
    /// knob's end.
    public var strain: Double { 3e-4 * tension }

    public var searching: Bool { search > 1.02 }
}

/// The tape's motion at the drum, line by line: the capstan servo holding it
/// where the control track says the tracks are, stick-slip where the tape
/// drags, and picture search running it n× as fast.
///
/// Where the tape is along its length decides two things. Across the
/// tracks: a tape `d` track pitches out of place puts the heads `d` pitches
/// off their tracks (the tracks are slanted, so moving the tape along moves
/// them sideways under the heads). Along them: the same shift moves the
/// heads along the track by d·(1.5 lines in SP), so the signal arrives that
/// much early or late — a time-base error.
///
/// The servo: the control head reads a pulse recorded at the bottom edge
/// once a frame; the capstan's speed is corrected (a type-2 loop, ~1.4 Hz)
/// to keep the pulse at the drum's phase plus the tracking control's delay.
/// A pulse lost to a damaged edge leaves the capstan running at its last
/// speed, so the tracking drifts until the next; a crinkle can fake one and
/// kick the servo off.
///
/// Stick-slip: where the binder is gummy (sticky shed, mold), the tape
/// sticks on the stationary guides while the capstan pulls; the tape at the
/// drum falls behind until the tension tears it loose, and it springs
/// forward past where it should be. Microns of lag, a sawtooth at a kHz or
/// so — ragged, jittering picture edges.
///
/// Like the rest of the simulation, it depends only on the knobs over time
/// and the seed, so any moment can be reproduced by playing from the start.
final class TransportSimulator {
    let linesPerField: Int
    let seed: UInt64
    private(set) var params: TransportParams
    private(set) var tape: TapeParams

    struct Line: Equatable {
        /// Where the tape is along its length against where the heads
        /// expect it, in track pitches.
        var delta: Double
        /// The time-base error that puts on the signal, µs.
        var tbe: Double
    }

    fileprivate struct State {
        var line: Int64 = -1            // last line stepped
        var delta = 0.0                 // servo-held tape position error, pitches
        var speed = 0.0                 // capstan speed error, pitches per frame
        var integ = 0.0                 // servo's integral term
        var lag = [0.0, 0.0, 0.0]       // stick-slip lag at each guide, µm
        var breakAt = [8.0, 6.0, 5.0]   // lag at which each tears loose, µm
        var phase = 0.0                 // search: heads' offset at this field's start
        var rate = 0.0                  // search: pitches crossed per field
        var lines: [Line] = []
        var fields: [(field: Int64, phase: Double, rate: Double)] = []
    }
    private var s = State()
    private let cap: Int

    /// The control track's pulse is ~79 mm along the tape from its track's
    /// start (the VHS X-distance), at the bottom edge.
    static let controlOffset = 79.244
    static let controlY = 0.35

    init(linesPerField: Int, seed: UInt64, settings: GlitchSettings) {
        self.linesPerField = linesPerField
        self.seed = seed
        params = TransportParams(settings)
        tape = TapeParams(settings)
        cap = 4 * linesPerField + 64
    }

    func update(_ settings: GlitchSettings) {
        params = TransportParams(settings)
        tape = TapeParams(settings)
    }

    /// Back to the start of play: tape in place, servo locked.
    func reset() {
        s = State()
        s.lines.reserveCapacity(cap)
    }

    struct Snapshot { fileprivate let s: State }
    func snapshot() -> Snapshot { Snapshot(s: s) }
    func restore(_ snap: Snapshot) { s = snap.s }

    /// Tape position error and its time-base error at signal line j (as of
    /// the last line stepped, for lines not reached yet).
    func line(_ j: Int64) -> Line {
        let back = max(0, s.line - j)
        if s.lines.isEmpty { return Line(delta: 0, tbe: 0) }
        let n = Int64(s.lines.count)
        let i = back >= n ? 0 : n - 1 - back
        return s.lines[Int(i)]
    }

    /// Picture search: how far off its own track a head starts sweeping
    /// field f (pitches, wrapped to the nearest track of its azimuth), and
    /// how many it crosses in the sweep.
    func search(field f: Int64) -> (phase: Double, rate: Double) {
        if let e = s.fields.last(where: { $0.field == f }) { return (e.phase, e.rate) }
        if let last = s.fields.last, f > last.field {
            return (wrap2(last.phase + last.rate * Double(f - last.field)), last.rate)
        }
        return s.fields.first.map { ($0.phase, $0.rate) } ?? (0, 0)
    }

    /// Play on through signal line j.
    func advance(through j: Int64) {
        if s.lines.isEmpty { s.line = j - 1 }
        while s.line < j { step(s.line + 1) }
    }

    private func step(_ j: Int64) {
        let p = params
        let L = Int64(linesPerField)
        let f = floordiv(j, L), jf = posmod(j, L)
        let advance = p.format.advancePerField
        if jf == 0 || s.fields.isEmpty { fieldStep(f) }

        // The capstan moves the tape on; its speed error — the motor's own,
        // wandering with load, less the servo's correction — carries the
        // tape off its place (pitches per frame, two fields).
        let t = Double(j) * NTSCTiming.line * 1e-6
        let motor = 0.004 * (2 * GlitchRandom.uniform(seed, 69, 0) - 1)
            + 0.006 * GlitchRandom.value(seed, 60, t / 3)
        s.delta += (motor + s.speed) / Double(2 * L)
        // A gummy tape drags: the capstan slips a little against it.
        if tape.sticky > 0 {
            let st = Double(tape.sticky)
            let drag = st * st * 0.05 * (1 + GlitchRandom.value(seed, 61, t / 0.8))
            s.delta -= drag / Double(L)
        }

        // Stick-slip at the guides, where the binder is gummy here.
        let x = Double(f) * advance + Double(jf) / Double(L) * advance        // tape position, mm
        let tapeSeed = UInt64(tape.seed)
        let mold = Double(tape.mold) * max(0, GlitchRandom.value(tapeSeed, 63, x / 9))
        let mu = Double(tape.sticky) * (0.55 + 0.45 * GlitchRandom.value(tapeSeed, 62, x / 25)) + 0.4 * mold
        // The tape touches several fixed guides before the drum, each
        // sticking and slipping in its own rhythm; their lags add, so the
        // timing jerks irregularly.
        let perLine = 33.35 / Double(p.format.speed + 1) * NTSCTiming.line * 1e-3   // µm of tape a line
        for c in 0..<3 {
            let grip = mu * [1.0, 0.75, 0.55][c]
            if grip < 0.1 {
                s.lag[c] *= 0.8
                continue
            }
            // Stuck, the tape there falls behind at a share of the tape
            // speed (the rest is stretch between the guides and capstan).
            s.lag[c] += [0.3, 0.2, 0.15][c] * perLine
            if s.lag[c] >= s.breakAt[c] {
                // Torn loose: it springs forward past its place.
                s.lag[c] = -0.3 * s.lag[c]
                let u = GlitchRandom.uniform(seed, 64 + UInt64(c), j)
                s.breakAt[c] = (1.5 + 7 * grip) * (1 + 0.35 * p.tension) * (0.4 + 1.4 * u * u)
            }
        }
        let lag = s.lag.reduce(0, +)

        // The pinch roller's wobble, too fast for the servo (residual).
        let wobble = p.flutter * 0.03 * GlitchRandom.value(seed, 65, t * 3.5)
        let delta = s.delta + wobble + lag / (advance * 1000)
        let alpha = p.format.trackOffsetLines
        // Soft-limited to under half a line: past that the heads are on the
        // next track and the picture is noise anyway.
        let tbe = NTSCTiming.line * 0.45 * tanh(alpha * delta / 0.45)
        if s.lines.count >= cap { s.lines.removeFirst(s.lines.count - cap + 1) }
        s.lines.append(Line(delta: delta, tbe: tbe))
        s.line = j
    }

    private func fieldStep(_ f: Int64) {
        let p = params
        // Picture search: the capstan runs n×, the servo is off, and each
        // sweep starts n−1 tracks on from the last.
        if p.searching {
            let prev = s.fields.last
            s.phase = prev.map { wrap2($0.phase + $0.rate) } ?? 0
            s.rate = p.search - 1
        } else {
            if s.rate != 0 || s.phase != 0 {
                // Back to play: the servo has to pull the tape back in.
                s.delta += wrap2(s.phase + s.rate)
                s.phase = 0; s.rate = 0
            }
            if posmod(f, 2) == 0 { servo(f) }
        }
        s.fields.append((f, s.phase, s.rate))
        if s.fields.count > 16 { s.fields.removeFirst() }
    }

    /// One control-track pulse (once a frame).
    private func servo(_ f: Int64) {
        let p = params
        let pitch = p.format.trackPitch * 1000
        // Where the tape should be: the tracking control's offset, plus the
        // recording deck's own (its control head sat a few µm elsewhere).
        let recorded = 1.5 * (2 * Double(TapeSurface.uni(tape.seed, 95, 0, 0)) - 1) / pitch
        let target = p.tracking + recorded
        // The pulse, as the control head reads it off the bottom edge.
        let at = TapePosition(x: TapeGeometry.trackOrigin(field: f, format: p.format) + Self.controlOffset,
                              y: Self.controlY)
        let edge = TapeSurface.at(at, tape, detail: false)
        let amplitude = Double(edge.output) * exp(-2 * .pi * Double(edge.lift) / 12)
        let u = GlitchRandom.uniform(seed, 66, f)
        var measured: Double? = amplitude * (0.85 + 0.3 * u) > 0.5 ? s.delta - target : nil
        // A crinkle passing the head can fake a pulse.
        let fake = 0.5 * Double(TapeSurface.smoothstep(0.8, 2.5, edge.lift))
        if GlitchRandom.uniform(seed, 67, f) < fake {
            measured = GlitchRandom.uniform(seed, 68, f) - 0.5
        }
        // No pulse: the correction stays where it was, and the tape drifts
        // with the motor until the next one.
        guard let e = measured else { return }
        s.speed = -(0.377 * e + s.integ)
        s.integ += 0.0986 * e
    }
}

/// x wrapped to (−1, 1]: the offset from the nearest track two pitches
/// apart (the nearest of the head's own azimuth).
@inline(__always)
func wrap2(_ x: Double) -> Double {
    var r = x.truncatingRemainder(dividingBy: 2)
    if r > 1 { r -= 2 } else if r <= -1 { r += 2 }
    return r
}
