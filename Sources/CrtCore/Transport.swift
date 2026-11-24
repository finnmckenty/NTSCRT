import Foundation

/// The deck's transport as the simulation uses it, from the knobs: how the
/// tape is moved past the drum, which decides where the heads' sweep falls
/// on the recorded tracks and when the signal on them arrives.
public struct TransportParams: Equatable {
    /// Back tension against the recording deck's: the knob (−1…1) as it is
    /// up to half, then on a straight line to ±`1 + tensionTopEnd` at its
    /// ends (TapeParams.topEnd). Half a knob is a band brake out of
    /// adjustment; the ends are a tape stretched by a deck that chewed it,
    /// or a supply reel hardly braked at all.
    public var tension: Double
    /// (At ±1 — the old full knob — the top of the picture barely hooked on
    /// a TV with the default AFC, which rides out all but 4% of the jump
    /// before the picture starts.)
    public static let tensionTopEnd = 3.0
    /// Worn drum motor, belts and pinch roller, 0…1.
    public var flutter: Double
    /// The tracking control: where the servo puts the tape, in track
    /// pitches (±1 is a whole track).
    public var tracking: Double
    /// Picture search multiple (1 = normal play).
    public var search: Double
    public var format: TapeFormat

    public init(_ s: GlitchSettings) {
        let bt = min(1, max(-1, s["back_tension"]))
        tension = (bt < 0 ? -1 : 1) * Double(TapeParams.topEnd(Float(abs(bt)), Float(Self.tensionTopEnd)))
        // On the damage knobs' curve (TapeParams.topEnd): realistic up to
        // half, then up to 5× (at its realistic most the TV's AFC rode out
        // nearly all of it).
        flutter = Double(TapeParams.topEnd(Float(min(1, max(0, s["transport_flutter"]))),
                                           TapeParams.topEndGains["transport_flutter"] ?? 0))
        // The knob on a curve: its first half moves the heads three
        // quarters of the way off their tracks (the picture just gets
        // noisier); the rest is where noise bands break out and take over.
        let k = min(1, max(-1, s["tracking_offset"]))
        tracking = (k < 0 ? -1 : 1) * (1 - (1 - abs(k)) * (1 - abs(k)))
        search = min(9, max(1, s["search_speed"]))
        format = TapeFormat(s)
    }

    /// How much longer the tape is stretched than when it was recorded: the
    /// strain of ~0.85 N more tension on a VHS tape's 0.24 mm² of PET at
    /// tension 1 — a 13 µs jump at the head switch; 53 µs at the knob's end
    /// (0.3% longer: a tape a deck has stretched). The steady part: the
    /// tension arm hunts around it (ReceiverSimulator.strain).
    public var strain: Double { 8e-4 * tension }

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
/// A sticky tape (binder gone gummy: sticky shed, and mold a little) grabs
/// and lets go: `StickyTape`. Not a constant jitter — the tape runs clean,
/// then at a gummy patch it sticks on the guides and drum, the capstan
/// drags it on, the tension climbs, and it tears loose and springs back.
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
        /// How much a sticky patch is stretching the tape here (strain, on
        /// top of the back tension's).
        var strain = 0.0
    }

    fileprivate struct State {
        var line: Int64 = -1            // last line stepped
        var delta = 0.0                 // servo-held tape position error, pitches
        var speed = 0.0                 // capstan speed correction, pitches per frame
        var kick = 0.0                  // this frame's phase correction, pitches
        var integ = 0.0                 // servo's integral term
        var phase = 0.0                 // search: heads' offset at this field's start
        var rate = 0.0                  // search: pitches crossed per field
        /// The last `cap` lines, as a ring: once full, `oldest` is where the
        /// next line goes. (Shifting an array down by one per line cost a
        /// 17 KB memmove for each of ~15,700 lines a second — most of a
        /// re-simulation.)
        var lines: [Line] = []
        var oldest = 0
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
        return s.lines[(s.oldest + Int(i)) % s.lines.count]
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
        s.delta += (motor + s.speed + s.kick) / Double(2 * L)
        // A sticky patch under the guides: the tape is held back.
        let x = Double(f) * advance + Double(jf) / Double(L) * advance        // tape position, mm
        let grab = StickyTape.at(x, tape)
        // The capstan slips against the held tape, so the tape falls
        // behind its place (the servo sees that, and pulls it back over the
        // next half second: the tracking sags and recovers).
        if grab.hold > 0 { s.delta -= StickyTape.slip * grab.hold / Double(L) }

        // The pinch roller's wobble, too fast for the servo (residual).
        let wobble = p.flutter * 0.03 * GlitchRandom.value(seed, 65, t * 3.5)
        let delta = s.delta + wobble
        let alpha = p.format.trackOffsetLines
        // Soft-limited to under half a line: past that the heads are on the
        // next track and the picture is noise anyway.
        // Measured from the nearest track of the heads' own azimuth: a tape
        // a whole frame out (servo lost, drifting) is back on a track.
        var tbe = NTSCTiming.line * 0.45 * tanh(alpha * wrap2(delta) / 0.45)
        // Held, the tape sings: the squeal, a steady tone that swells until
        // it lets go.
        // (Its pitch wavers: a stick-slip tone, not a tuning fork.)
        if grab.squeal > 0 {
            tbe += grab.squeal * sin(2 * .pi * grab.pitch * t + 1.5 * GlitchRandom.value(seed, 106, t * 40))
        }
        let line = Line(delta: delta, tbe: tbe, strain: grab.strain)
        if s.lines.count < cap {
            s.lines.append(line)
        } else {
            s.lines[s.oldest] = line
            s.oldest = (s.oldest + 1) % cap
        }
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
            s.kick = 0
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
        // The pulse, as the control head reads it off the bottom edge. The
        // control amplifier has gain to spare: a weaker tape overall (worn
        // oxide) still reads, but missing coating or the tape held off the
        // head by a crinkle or mold loses the pulse.
        let at = TapePosition(x: TapeGeometry.trackOrigin(field: f, format: p.format) + Self.controlOffset,
                              y: Self.controlY)
        let edge = TapeSurface.at(at, tape, detail: false)
        let amplitude = Double(edge.output / tape.remanence) * exp(-2 * .pi * Double(edge.lift) / 12)
        let u = GlitchRandom.uniform(seed, 66, f)
        // The phase detector compares the pulse with the drum's own once-a-
        // frame reference, so it reads the error to the nearest frame: it
        // pulls the tape onto the nearest pair of tracks, never more than a
        // track away.
        var measured: Double? = amplitude * (0.85 + 0.3 * u) > 0.5 ? wrap2(s.delta - target) : nil
        // A crinkle passing the head can fake a pulse.
        let fake = 0.5 * Double(TapeSurface.smoothstep(0.8, 2.5, edge.lift))
        if GlitchRandom.uniform(seed, 67, f) < fake {
            measured = GlitchRandom.uniform(seed, 68, f) - 0.5
        }
        // No pulse: the capstan holds the speed it had settled on (its
        // speed loop runs off the motor's own tachometer), and the tape
        // drifts with the motor's wander until the next one. The phase
        // correction is a nudge of one frame, not a speed held until the
        // next pulse — held over a run of missing pulses it would build into
        // a swing the next pulse overcorrects, ever wider.
        s.kick = 0
        guard let e = measured else { return }
        s.speed = -s.integ
        s.kick = -0.377 * e
        s.integ = min(0.15, max(-0.15, s.integ + 0.0986 * e))
    }
}

/// Where a sticky tape grabs.
///
/// Binder that has taken up moisture is gummy in patches along the tape.
/// Sources describe what that does as squeal, the tape dragging and jerking
/// through the path, and residue on the heads (archive guides, the AV
/// Artifact Atlas's stiction entry, repair notes) — not a jitter on every
/// line. So: the tape plays clean until a patch reaches the guides and
/// drum. There it holds; the capstan keeps pulling, so the tape between
/// stretches (tension climbs: the picture skews, more each field), the
/// capstan slips (the tracking sags) and the tape squeals (a tone, swelling).
/// Then it tears loose: the tension is gone in a millisecond, the picture
/// below that line lurches sideways, and the tape rings like the spring it
/// is for a couple of fields.
///
/// A function of the place on the tape alone, so it is there again on every
/// play, somewhere else on another cassette, and three times as long at EP's
/// tape speed. How often, how long and how hard are choices: nothing here
/// is measured from a tape.
enum StickyTape {
    struct Grab {
        /// The tape's extra stretch (strain).
        var strain = 0.0
        /// How hard it is held, 0…1 (what the capstan slips against).
        var hold = 0.0
        /// The squeal: amplitude (µs) and pitch (Hz).
        var squeal = 0.0
        var pitch = 0.0
    }

    /// Patches are dealt one to a stretch of tape this long, mm (0.3 s at SP).
    static let stretch = 10.0
    /// The stretch a full-strength patch puts on the tape before it lets
    /// go: 36 µs of skew over a field.
    static let strain = 2.2e-3
    /// The capstan's slip against a full-strength hold, track pitches a field.
    static let slip = 0.4
    /// The squeal's size at full strength, µs.
    static let squeal = 0.3
    /// Letting go takes this much tape, mm (0.75 ms at SP).
    static let release = 0.025

    /// How sticky the tape is overall, 0…1: Sticky shed, and a little from
    /// mold (its colonies are tacky too).
    static func stickiness(_ t: TapeParams) -> Double { min(1, Double(t.sticky) + 0.25 * Double(t.mold)) }

    /// The patch in stretch `c`, if it has one: where it starts and ends
    /// (mm) and how hard it holds.
    static func patch(_ c: Int64, _ t: TapeParams) -> (start: Double, end: Double, grip: Double, pitch: Double)? {
        let st = stickiness(t)
        guard st > 0 else { return nil }
        let seed = UInt64(t.seed)
        // A few at a low setting (one every three seconds at a quarter,
        // one a second at half), one in every stretch at full: three a
        // second, the tape held two thirds of the time.
        guard GlitchRandom.uniform(seed, 101, c) < min(1, pow(st, 1.6)) else { return nil }
        let length = (2 + 7 * GlitchRandom.uniform(seed, 102, c)) * (0.5 + 0.5 * st)
        let start = (Double(c) + 0.9 * GlitchRandom.uniform(seed, 103, c)) * stretch
        // (How hard a patch holds grows less with the knob than how many
        // there are: a slightly sticky tape grabs rarely, but it does grab.)
        let grip = (0.35 + 0.65 * st) * (0.5 + 0.5 * GlitchRandom.uniform(seed, 104, c))
        return (start, start + length, grip, 950 + 800 * GlitchRandom.uniform(seed, 105, c))
    }

    static func at(_ x: Double, _ t: TapeParams) -> Grab {
        guard t.sticky > 0 || t.mold > 0 else { return Grab() }
        var g = Grab()
        let c = Int64((x / stretch).rounded(.down))
        // This stretch's patch and the one before's (still ringing, or
        // running over the boundary).
        for k in [c - 1, c] {
            guard let p = patch(k, t), x >= p.start else { continue }
            if x < p.end {
                // Held: the tension climbs, slowly at first.
                let q = (x - p.start) / (p.end - p.start)
                g.strain += strain * p.grip * q * q
                g.hold = max(g.hold, p.grip * min(1, q * 4))
                g.squeal = squeal * p.grip * q
                g.pitch = p.pitch
            } else {
                // Let go: the tension falls away and the tape rings.
                let d = x - p.end
                guard d < 4 else { continue }
                let fall = 1 - min(1, d / release)
                let ring = -0.35 * (1 - fall) * exp(-d / 0.5) * cos(2 * .pi * d / 0.8)
                g.strain += strain * p.grip * (fall * fall * (3 - 2 * fall) + ring)
            }
        }
        return g
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
