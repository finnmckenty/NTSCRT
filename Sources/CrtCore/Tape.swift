import Foundation

/// VHS tape geometry (SMPTE 32M / IEC 774-1, NTSC SP): the slanted video
/// tracks the deck's two heads write, one per field, across a 12.65 mm tape.
///
/// Coordinates on the tape are millimeters: x along the tape (its length),
/// y across it from the bottom (reference) edge, where the control track
/// runs; the linear audio track is along the top edge. A track starts at the
/// bottom and rises at 5.97° to the tape's length, so height across the tape
/// is height in the picture, and a point on the tape is read in whichever
/// field's track passes over it.
public enum TapeGeometry {
    public static let width = 12.65
    /// Video writing speed (head relative to tape), µm per µs (= m/s).
    public static let writingSpeed = 5.8
    /// Tape transport speed, mm per field (33.35 mm/s ÷ 59.94).
    public static let advancePerField = 33.35 / NTSCTiming.fieldRate
    /// The track's angle to the tape's length (moving tape).
    public static let angle = 5.97 * Double.pi / 180
    /// One field's track (writing speed × field time), mm.
    public static let trackLength = writingSpeed * 1000 / NTSCTiming.fieldRate
    /// Height above the bottom edge where a track starts.
    public static let trackStart = 1.0
    /// Distance between neighboring tracks' centerlines (= the SP head width).
    public static var trackPitch: Double { advancePerField * sin(angle) }
    /// Track per NTSC line (63.556 µs at the writing speed), mm.
    public static var lineLength: Double { trackLength / NTSCTiming.linesPerField }

    /// Where along its track (mm from the start) signal line `fieldLine` of a
    /// raster with `linesPerField` lines is at `u` µs. Lines are spaced by the
    /// raster's share of the track, and each line runs the real length of an
    /// NTSC line — so on a raster taller than a field, neighboring lines
    /// overlap the way an interlaced frame's two fields' lines lie side by
    /// side on neighboring tracks.
    public static func alongTrack(fieldLine: Double, u: Double, linesPerField: Int) -> Double {
        fieldLine / Double(linesPerField) * trackLength + u / NTSCTiming.line * lineLength
    }

    /// The track of field `field` starts this far along the tape (mm).
    public static func trackOrigin(field: Int64, format: TapeFormat = .sp) -> Double {
        Double(field) * format.advancePerField
    }

    /// The tape point `along` mm up the track of field `field`, offset
    /// `across` mm sideways (toward the top edge).
    public static func point(field: Int64, along: Double, across: Double = 0,
                             format: TapeFormat = .sp) -> TapePosition {
        let x = trackOrigin(field: field, format: format) + along * cos(angle) - across * sin(angle)
        let y = trackStart + along * sin(angle) + across * cos(angle)
        return TapePosition(x: x, y: y)
    }
}

/// The speed a tape was recorded at. The drum turns at the same rate in all
/// three, so the tracks are as long and the signal on them the same; the
/// tape just moves on less between fields, so the tracks are narrower and
/// lie closer — a deck records LP and EP with narrower heads, which in EP
/// are wider than the track and overwrite part of the one before.
public struct TapeFormat: Equatable, Sendable {
    /// 0 SP (standard play), 1 LP (long play, ½ speed), 2 EP (extended, ⅓).
    public let speed: Int
    public init(speed: Int) { self.speed = min(2, max(0, speed)) }

    public init(_ s: GlitchSettings) { self.init(speed: Int(s["tape_speed"].rounded())) }

    public static let sp = TapeFormat(speed: 0)
    public static let names = ["SP", "LP", "EP"]

    /// Tape transport per field, mm.
    public var advancePerField: Double { TapeGeometry.advancePerField / Double(speed + 1) }
    /// Neighboring tracks' spacing across the tape, mm (58, 29, 19.3 µm).
    public var trackPitch: Double { advancePerField * sin(TapeGeometry.angle) }
    /// The video heads' width, mm: full-width SP heads, and the narrow
    /// heads of a four-head deck for LP and EP.
    public var headWidth: Double { speed == 0 ? 0.058 : 0.026 }
    /// What's left of each recorded track once the next has been written
    /// over its edge, mm.
    public var trackWidth: Double { min(headWidth, trackPitch) }
    /// How far a track's lines sit along from the neighboring track's, in
    /// lines (1.5 SP, 0.75 LP, 0.5 EP): the tracks are shifted one advance
    /// along the tape.
    public var trackOffsetLines: Double { advancePerField * cos(TapeGeometry.angle) / TapeGeometry.lineLength }
    /// The noise a head picks up, against an SP head's. A narrow track gives
    /// a third of SP's carrier in EP (−9.5 dB), but decks make most of it
    /// back with their narrow heads (finer gaps, more efficient cores, a
    /// preamp matched to them): spec sheets give much the same video S/N in
    /// every speed (Sony SVT-S480ES: VHS 44 dB in SP and EP). Set to leave
    /// LP about 1.5 dB and EP 2.5 dB of carrier-to-noise behind SP; the
    /// narrow track still makes them less forgiving of the heads straying
    /// off it.
    public var noiseScale: Double { [1, 0.53, 0.445][speed] }

    /// What a head `delta` track pitches off its own track's center reads
    /// of the three tracks nearest it (`center` − 1, `center`, `center` + 1):
    /// each one's share of a full SP track's output for the FM carrier and
    /// for the color-under. Tracks an odd number from its own were written
    /// by the other head, with the other azimuth (±6°): across the width
    /// the head overlaps, the recorded pattern is tilted 12° to its gap, so
    /// short wavelengths cancel (azimuth loss) — the FM almost entirely, the
    /// long color-under far less.
    public func read(delta: Double) -> (center: Int, fm: SIMD3<Double>, color: SIMD3<Double>) {
        let p = trackPitch * 1000, w = headWidth * 1000, tw = trackWidth * 1000
        let center = Int((delta).rounded())
        let lo = delta * p - w / 2, hi = delta * p + w / 2
        var fm = SIMD3<Double>(repeating: 0), color = SIMD3<Double>(repeating: 0)
        for t in 0..<3 {
            let k = center - 1 + t
            let o = max(0, min(hi, Double(k) * p + tw / 2) - max(lo, Double(k) * p - tw / 2))
            let share = o / 58
            if k % 2 == 0 {
                fm[t] = share; color[t] = share
            } else {
                fm[t] = share * Self.azimuthLoss(width: o, mhz: Self.fmMHz)
                color[t] = share * Self.azimuthLoss(width: o, mhz: VcrChannel.colorUnderMHz)
            }
        }
        return (center, fm, color)
    }

    /// The FM carrier's frequency for azimuth loss (mid-band).
    static let fmMHz = 4.0
    /// tan of the 12° between the two heads' azimuths.
    static let azimuthTan = tan(12 * Double.pi / 180)

    /// Amplitude (signed) a head reads of a track recorded at the other
    /// azimuth across `width` µm, at `mhz`.
    public static func azimuthLoss(width: Double, mhz: Double) -> Double {
        let lambda = TapeGeometry.writingSpeed / mhz
        let x = Double.pi * width * azimuthTan / lambda
        return x < 1e-6 ? 1 : sin(x) / x
    }
}

/// A point on the tape, split for the GPU's 32-bit floats: `base` whole
/// tenths of a millimeter along the tape plus `offset` more (in tenths too).
public struct TapePosition: Equatable {
    public var base: Int32
    public var offset: Float
    public var y: Float

    public init(x: Double, y: Double) {
        let tenths = x * 10
        let b = tenths.rounded(.down)
        base = Int32(clamping: Int64(b))
        offset = Float(tenths - b)
        self.y = Float(y)
    }

    public init(base: Int32, offset: Float, y: Float) {
        self.base = base; self.offset = offset; self.y = y
    }
}

/// The tape's condition as the simulation uses it, from the Tape knobs.
public struct TapeParams: Equatable {
    public var seed: UInt32
    public var wear: Float
    public var dropouts: Float
    public var scratches: Float
    public var creases: Float
    public var edge: Float
    public var mold: Float
    public var vaseline: Float
    /// Binder breaking down (sticky shed): the tape drags and sheds.
    public var sticky: Float

    public init(_ s: GlitchSettings) {
        seed = UInt32(truncatingIfNeeded: Int(s["tape_seed"].rounded()) &* 7919 &+ 17)
        func u(_ k: String) -> Float { Float(min(1, max(0, s[k]))) }
        func amount(_ k: String) -> Float { Self.amount(k, u(k)) }
        wear = amount("tape_wear")
        dropouts = amount("tape_dropouts")
        scratches = amount("tape_scratches")
        creases = amount("tape_creases")
        edge = amount("tape_edge_damage")
        mold = u("tape_mold")
        vaseline = u("tape_vaseline")
        sticky = u("tape_sticky")
    }

    /// How far past a realistic worst case each damage knob goes at full.
    /// Up to half a knob is calibrated to real tapes; above, the amount
    /// grows on a straight line to 1 + gain at full, so the top of the
    /// range is a wrecked tape (the realistic maximum read as too weak:
    /// measured on flat gray at a 320 downscale, full Oxide flaws went from
    /// 2% of the picture damaged to 14%, Scratches 0% → 15%, Edge damage
    /// 3% → 13%, Creases 2% → 5% with 14% peaks). Built-in looks and tape
    /// choices were rescaled (`knob(forAmount:)`) to render as before.
    /// (Wear, Oxide flaws, Scratches and Edge damage have measured curves:
    /// `curves`.)
    public static let topEndGains: [String: Float] = [
        "tape_creases": 4,
        // The deck's Flutter (Transport) too: at 5× the picture's verticals
        // go ragged and wavy; at the realistic most they barely moved.
        "transport_flutter": 4,
    ]

    /// Measured slider curves: each knob's amount (1 = the realistic worst)
    /// at the slider's tenths, so the picture's change grows as the slider
    /// to the power 1.5 (averaged over an EP third copy and an SP original).
    /// 0.27.0's straight lines above half left these nearly flat until 50–80%
    /// and put most of the effect at the very top; the realistic range of
    /// Scratches and Edge damage barely shows, so it is the first tenth.
    /// Wear goes to 1.85 (18.5 dB: past the FM threshold — heavy noise on
    /// SP, LP and EP tear), with its color spared (`DeckParams.colorBoost`).
    static let curves: [String: [Float]] = [
        "tape_wear": [0, 0.259, 0.648, 0.955, 1.202, 1.391, 1.540, 1.640, 1.724, 1.785, 1.850],
        // (Measured again when flaws became dropouts — dashes, not bands:
        // their numbers grow as the amount squared, cubed past 1, so the
        // realistic range is the first sixth of the travel.)
        "tape_dropouts": [0, 0.679, 1.13, 1.396, 1.631, 1.87, 2.108, 2.333, 2.51, 2.732, 3.0],
        "tape_scratches": [0, 0.759, 1.281, 1.822, 2.073, 2.289, 2.516, 2.777, 3.069, 3.430, 4.0],
        "tape_edge_damage": [0, 0.703, 0.743, 0.800, 0.888, 0.934, 0.987, 1.056, 1.190, 1.329, 1.45],
    ]

    /// A damage knob's amount for its slider position: its measured curve,
    /// or its top end (`topEndGains`), or the knob itself.
    public static func amount(_ key: String, _ k: Float) -> Float {
        let k = min(1, max(0, k))
        guard let c = curves[key] else { return topEnd(k, topEndGains[key] ?? 0) }
        let x = k * 10
        let i = min(9, Int(x))
        return c[i] + (c[i + 1] - c[i]) * (x - Float(i))
    }

    /// Oxide flaws' curve through 0.28: where its slider stood for a given
    /// amount then.
    static let curvesIn028: [String: [Float]] = [
        "tape_dropouts": [0, 0.195, 0.473, 0.754, 0.931, 1.120, 1.322, 1.607, 2.124, 2.480, 3.0],
    ]

    /// Where the slider stood in 0.28 for `amount`: what the tape choices
    /// and looks from before the curves are given. For Oxide flaws that is
    /// no longer the same amount — the same flakes show far less now that
    /// they are dropouts the deck compensates, not bands that tear the
    /// picture — so a look keeps its place on the slider, its share of the
    /// control's full effect, instead.
    public static func knobIn028(_ key: String, forAmount amount: Double) -> Double {
        knob(forAmount: amount, on: curvesIn028[key] ?? curves[key], key: key)
    }

    /// The slider position that gives `amount` (the inverse of `amount`).
    public static func knob(_ key: String, forAmount amount: Double) -> Double {
        knob(forAmount: amount, on: curves[key], key: key)
    }

    private static func knob(forAmount amount: Double, on curve: [Float]?, key: String) -> Double {
        guard let c = curve else { return knob(forAmount: amount, gain: Double(topEndGains[key] ?? 0)) }
        let a = Float(min(Double(c[10]), max(0, amount)))
        for i in 0..<10 where a <= c[i + 1] {
            let span = c[i + 1] - c[i]
            return Double((Float(i) + (span > 0 ? (a - c[i]) / span : 0)) / 10)
        }
        return 1
    }

    /// A knob's amount as 0.27.0 read it (straight lines above half), for
    /// looks saved then and before.
    static let gainsIn027: [String: Double] = [
        "tape_wear": 0.85, "tape_dropouts": 2, "tape_scratches": 3, "tape_edge_damage": 0.45,
    ]
    public static func amountIn027(_ key: String, _ k: Double) -> Double {
        let g = gainsIn027[key] ?? 0
        return k <= 0.5 ? k : k + g * (k - 0.5) / 0.5
    }

    /// The knob as is up to half; above, it rises on a straight line to
    /// 1 + `gain` at full.
    public static func topEnd(_ k: Float, _ gain: Float) -> Float {
        guard k > 0.5 else { return k }
        return k + gain * (k - 0.5) / 0.5
    }

    /// The knob setting that gives `amount` (the inverse of `topEnd`): what
    /// a value from before the top-end gains becomes, to look the same.
    public static func knob(forAmount amount: Double, gain: Double) -> Double {
        guard amount > 0.5 else { return amount }
        return (amount + gain) / (1 + 2 * gain)
    }

    /// Remanent magnetization relative to a new tape: wear loses up to 10 dB.
    public var remanence: Float { powf(10, -wear * 10 / 20) }
    /// Surface roughness as head-to-tape spacing, µm.
    public var roughness: Float { 0.015 + 0.1 * wear }
    /// Chance that a 0.1 mm square holds a pinhole.
    public var pinholeChance: Float { (0.05 + 6 * dropouts + 2 * wear) * 0.01 }
    /// Flakes of missing coating per 0.3 × 0.33 mm cell (up to three; the
    /// fraction is the chance of the next one). The square of the knob's
    /// amount up to the realistic worst, its cube above.
    public var flakeChance: Float {
        min(3, 0.0001 + 0.12 * dropouts * dropouts * max(1, dropouts) + 0.012 * wear + 0.012 * mold)
    }
    /// What one flake sheds. Evened out above one flake a cell, so the
    /// top of the knob is more dropouts, not a deck that clogs at once.
    public var flakeShed: Float { 1.2 / max(1, flakeChance) }
}

/// What the head finds at one point of the tape.
public struct TapePoint: Equatable {
    /// How far the tape surface is held off the head, µm (roughness, creases,
    /// crinkled edges, mold), not counting a film on it.
    public var lift: Float
    /// A film on the tape (Vaseline), µm: the head rides on it.
    public var film: Float
    /// Magnetization there relative to a new tape (0 where coating is gone).
    public var output: Float
    /// How much the tape sheds there (oxide, mold): what collects on heads.
    public var shed: Float
}

/// The tape's surface: a procedural map from a position on the tape to its
/// condition there, the same on the CPU (this) and the GPU (`metalSource`,
/// which must be kept in step). Every flaw has a size and a place on the
/// tape, generated from the cassette's seed cell by cell, so it is always
/// there when the heads come back over it.
public enum TapeSurface {

    // MARK: hashing (identical to the shader's)

    @inline(__always) static func hash(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
        var h = a &* 0x8DA6_B343 ^ b &* 0xD816_3841 ^ c &* 0xCB1A_B31F ^ d &* 0x1656_67B1
        h ^= h >> 15; h = h &* 0x2C1B_3C6D; h ^= h >> 12; h = h &* 0x297A_2D39; h ^= h >> 15
        return h
    }

    @inline(__always) static func uni(_ a: UInt32, _ b: UInt32, _ c: Int32, _ d: Int32) -> Float {
        (Float(hash(a, b, UInt32(bitPattern: c), UInt32(bitPattern: d)) >> 8) + 0.5) * (1 / 16_777_216)
    }

    @inline(__always) static func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    @inline(__always) static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// The cell of size `q` tenths of a millimeter holding x, and how far
    /// into it x is (0–1).
    @inline(__always) static func cell(_ p: TapePosition, _ q: Int32) -> (Int32, Float) {
        let whole = p.offset.rounded(.down)
        let t = p.base &+ Int32(whole)
        var c = t / q
        if t % q != 0 && t < 0 { c -= 1 }
        let local = (Float(t &- c &* q) + (p.offset - whole)) / Float(q)
        return (c, local)
    }

    /// Distance along the tape from x to `cell`·q + `frac`·q (tenths of a mm,
    /// signed).
    @inline(__always) static func dx(_ p: TapePosition, cell c: Int32, q: Int32, frac: Float) -> Float {
        Float(c &* q &- p.base) + frac * Float(q) - p.offset
    }

    @inline(__always) static func noise1(_ s: UInt32, _ k: UInt32, _ i: Int32, _ f: Float) -> Float {
        let a = uni(s, k, i, 0), b = uni(s, k, i &+ 1, 0)
        return a + (b - a) * smooth(f)
    }

    @inline(__always) static func noise2(_ s: UInt32, _ k: UInt32, _ i: Int32, _ fi: Float,
                                         _ j: Int32, _ fj: Float) -> Float {
        let a = uni(s, k, i, j), b = uni(s, k, i &+ 1, j)
        let c = uni(s, k, i, j &+ 1), d = uni(s, k, i &+ 1, j &+ 1)
        let u = smooth(fi), v = smooth(fj)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }

    /// The tape at `p`. `detail` includes flaws much smaller than a track
    /// (pinholes, scratches), which only matter to the picture, not to sync
    /// or to what the heads pick up. `flakes: false` leaves out the flakes
    /// too, for the deck's color loops, which hold through a dropout.
    /// What a new tape sheds (the same units as `TapePoint.shed`): enough
    /// that a deck never cleaned (Dirt buildup at full) clogs for a moment
    /// every half minute or so on any tape, and a cleaned one about never.
    static let baseShed: Float = 0.018

    public static func at(_ p: TapePosition, _ t: TapeParams, detail: Bool = true,
                          flakes: Bool = true) -> TapePoint {
        let s = t.seed
        let y = p.y
        var lift = t.roughness
        var out = t.remanence
        var film: Float = 0
        // Any tape sheds a trace as it runs; worn coating sheds a little
        // more everywhere; a hydrolyzed binder sheds gummy oxide all along
        // the tape.
        var shed: Float = baseShed + 0.02 * t.wear + 0.9 * t.sticky * t.sticky

        // Coating thickness varies a little from place to place.
        do {
            let (cx, fx) = cell(p, 5)
            let yy = y * 10
            let cy = Int32(yy.rounded(.down))
            out *= 1 + (0.04 + 0.1 * t.wear) * (2 * noise2(s, 1, cx, fx, cy, yy - Float(cy)) - 1)
        }

        // Pinholes: 3–45 µm voids in the oxide, any number per square.
        if detail && t.pinholeChance > 0 {
            let (cx, _) = cell(p, 1)
            let cy = Int32((y * 10).rounded(.down))
            for j in -1...1 {
                for i in -1...1 {
                    let ci = cx &+ Int32(i), cj = cy &+ Int32(j)
                    guard uni(s, 11, ci, cj) < t.pinholeChance else { continue }
                    let ddx = dx(p, cell: ci, q: 1, frac: uni(s, 12, ci, cj)) * 0.1
                    let ddy = (Float(cj) + uni(s, 13, ci, cj)) * 0.1 - y
                    let u = uni(s, 14, ci, cj)
                    let r = 0.003 * powf(15, u * u)
                    let d = (ddx * ddx + ddy * ddy).squareRoot()
                    if d < r { out *= smoothstep(r * 0.6, r, d) }
                }
            }
        }

        // Flakes: bits of coating gone (or held off the head by a speck of
        // debris), most of them about a track wide and a tenth of a line
        // long, a few several tracks wide and most of a line long: each is
        // a dropout, a short dash in the picture. Longer across the tape
        // than along it, as the tent around a speck is. The knob's top end
        // is more of them, not bigger ones (up to three to a cell a third
        // of a millimeter square), so a wrecked tape is a blizzard of
        // dashes, not bands.
        if flakes && t.flakeChance > 0 {
            let (cx, _) = cell(p, 3)
            let cy = Int32((y * 3).rounded(.down))
            let most = Int(t.flakeChance.rounded(.up))
            for j in -1...1 {
                for i in -1...1 {
                    let ci = cx &+ Int32(i), cj = cy &+ Int32(j)
                    for k in 0..<most {
                        // The cell's k-th flake (its own draws).
                        let sk = s &+ UInt32(k) &* 0x9E37_79B9
                        guard uni(sk, 21, ci, cj) < t.flakeChance - Float(k) else { continue }
                        let ddx = dx(p, cell: ci, q: 3, frac: uni(sk, 22, ci, cj)) * 0.1
                        let ddy = (Float(cj) + uni(sk, 23, ci, cj)) * 0.33333334 - y
                        let u = uni(sk, 24, ci, cj)
                        let r = 0.018 * powf(9, u * u)
                        let e = 0.5 + 0.6 * uni(sk, 25, ci, cj)
                        let d = ((ddx / e) * (ddx / e) + (ddy * e) * (ddy * e)).squareRoot()
                        if d < r * 1.5 {
                            // Half are gone outright; the rest keep a little
                            // signal (a dropout too shallow for the deck's
                            // compensator: sparkles, where the signal is weak).
                            let depth = min(1, 0.55 + 0.9 * uni(sk, 26, ci, cj))
                            out *= 1 - depth * (1 - smoothstep(r * 0.8, r, d))
                            shed += t.flakeShed * depth * (1 - smoothstep(r, r * 1.5, d))
                        }
                    }
                }
            }
        }

        // Lengthwise scratches from worn guides, along a stretch of tape.
        // Most are narrower than a track (6–80 µm), so they only weaken the
        // signal on the line that crosses them; the debris thrown up either
        // side holds the head off a little. A scratch isn't uniform: the
        // tape weaved sideways in the guide that made it (tens of µm, about
        // a picture line), and its depth and width vary, with skips.
        //
        // Past the realistic worst (scratches over 1: most of the knob)
        // there are more of them, up to one in every quarter-millimeter
        // lane, and more of them wide enough to show (at the realistic
        // worst three in four are narrower than half a track, and only
        // weaken a line; at the top most are a track wide) — but a scratch
        // stays a scratch, a line or three of the picture: the ridges of
        // debris beside it stop growing (`strong`) and its width nearly
        // does, or the top of the knob was bands of noise, like every other
        // kind of damage.
        if detail && t.scratches > 0 {
            let strong = min(1, t.scratches)
            let lane = Int32((y * 4).rounded(.down))
            let (sx, fx) = cell(p, 3000)
            let (c80, f80) = cell(p, 80), (c15, f15) = cell(p, 15)
            let (c200, f200) = cell(p, 200), (c120, f120) = cell(p, 120)
            for l in -1...1 {
                let li = lane &+ Int32(l)
                guard uni(s, 31, li, sx) < t.scratches * 0.3 else { continue }
                let a = uni(s, 32, li, sx), b = uni(s, 33, li, sx)
                guard fx >= min(a, b) * 0.6, fx <= 0.4 + max(a, b) * 0.6 else { continue }
                // This scratch's own variation along the tape.
                let ss = s ^ (UInt32(bitPattern: li) &* 0x9E37_79B9) ^ (UInt32(bitPattern: sx) &* 0x85EB_CA6B)
                let weave = 0.03 * (2 * noise1(ss, 37, c80, f80) - 1) + 0.012 * (2 * noise1(ss, 38, c15, f15) - 1)
                let yc = (Float(li) + 0.15 + 0.7 * uni(s, 34, li, sx)) * 0.25 + weave
                let u = uni(s, 35, li, sx)
                let w = (0.006 + 0.074 * powf(u, 3 - 0.6667 * (t.scratches - strong)))
                    * (0.6 + 0.4 * strong + 0.15 * (t.scratches - strong))
                    * (0.5 + noise1(ss, 39, c200, f200))
                let depth = smoothstep(0.3, 0.55, noise1(ss, 40, c120, f120))
                guard depth > 0 else { continue }
                let dy = abs(y - yc)
                if dy < w * 0.5 {
                    out *= 1 - 0.95 * depth
                    lift += 0.15 * depth * strong
                } else if dy < w * 1.5 {
                    lift += 0.35 * depth * strong * (1 - (dy - w * 0.5) / w)
                }
            }
        }

        // Creases across the tape, from one edge in, at a slant.
        if t.creases > 0 {
            let (sx, _) = cell(p, 400)
            for k in -1...1 {
                let ci = sx &+ Int32(k)
                guard uni(s, 41, ci, 0) < t.creases * 0.9 else { continue }
                let off = dx(p, cell: ci, q: 400, frac: uni(s, 42, ci, 0)) * 0.1
                let slant = tanf((uni(s, 43, ci, 0) - 0.5) * 0.7)
                let fromBottom = uni(s, 44, ci, 0) < 0.5
                let extent = Float(TapeGeometry.width) * (0.25 + 0.75 * uni(s, 45, ci, 0))
                let yy = fromBottom ? y : Float(TapeGeometry.width) - y
                guard yy < extent else { continue }
                let reach = smoothstep(extent, extent * 0.8, yy)
                let w = 0.3 + 2.7 * powf(uni(s, 46, ci, 0), 1.5)
                let peak = (0.5 + 3.5 * powf(uni(s, 47, ci, 0), 1.5)) * (0.4 + 0.6 * t.creases)
                // The crease runs along x = anchor + yy·slant.
                let dd = (off + yy * slant) / w
                guard abs(dd) < 4 else { continue }
                let profile = expf(-dd * dd) * (0.75 + 0.25 * cosf(dd * 9))
                lift += peak * profile * reach
                out *= 1 - 0.3 * profile * reach
            }
        }

        // Crinkled edges, along damaged stretches of the tape.
        if t.edge > 0 {
            for side in 0..<2 {
                let k = UInt32(51 + side * 4)
                let yy = side == 0 ? y : Float(TapeGeometry.width) - y
                let (c60, f60) = cell(p, 600)
                let stretch = noise1(s, k, c60, f60)
                let damaged = smoothstep(t.edge * 0.85, t.edge * 0.85 - 0.1, stretch)
                guard damaged > 0 else { continue }
                let (c20, f20) = cell(p, 200)
                let reach = 0.3 + 1.9 * t.edge * (0.5 + 0.5 * noise1(s, k + 1, c20, f20))
                guard yy < reach else { continue }
                let (c1, f1) = cell(p, 12)
                let crinkle = noise1(s, k + 2, c1, f1)
                lift += damaged * t.edge * (1 + 2.5 * crinkle * crinkle) * powf(1 - yy / reach, 0.7)
            }
        }

        // Mold colonies, thickest toward the edges.
        if t.mold > 0 {
            let (cx, _) = cell(p, 40)
            let cy = Int32((y / 4).rounded(.down))
            for j in -1...1 {
                for i in -1...1 {
                    let ci = cx &+ Int32(i), cj = cy &+ Int32(j)
                    let ycen = (Float(cj) + uni(s, 63, ci, cj)) * 4
                    guard ycen > -1, ycen < Float(TapeGeometry.width) + 1 else { continue }
                    let edgeNear = 1 - min(1, min(abs(ycen), abs(Float(TapeGeometry.width) - ycen)) / 6.3)
                    guard uni(s, 61, ci, cj) < min(0.95, t.mold * (0.3 + 1.3 * edgeNear)) else { continue }
                    let ddx = dx(p, cell: ci, q: 40, frac: uni(s, 62, ci, cj)) * 0.1
                    let ddy = ycen - y
                    let d = (ddx * ddx + ddy * ddy).squareRoot()
                    let big = (0.35 + 2.0 * powf(uni(s, 64, ci, cj), 1.3)) * (0.6 + 0.4 * t.mold)
                    guard d < big * 1.4 else { continue }
                    // A ragged outline: the radius wanders with direction.
                    let turn = (atan2f(ddy, ddx) / (2 * .pi) + 0.5) * 6
                    let ti = Int32(turn.rounded(.down))
                    let a0 = uni(s, 65, ci &* 7 &+ (ti % 6), cj), a1 = uni(s, 65, ci &* 7 &+ ((ti + 1) % 6), cj)
                    let rr = big * (0.7 + 0.6 * (a0 + (a1 - a0) * smooth(turn - Float(ti))))
                    var dens = 1 - smoothstep(rr * 0.35, rr, d)
                    guard dens > 0 else { continue }
                    let (fx3, ff3) = cell(p, 3)
                    let fy3 = y * 0.33 * 10
                    let gy = Int32(fy3.rounded(.down))
                    dens *= 0.55 + 0.45 * noise2(s, 66, fx3, ff3, gy, fy3 - Float(gy))
                    lift += dens * (0.5 + 2.5 * t.mold)
                    out *= 1 - 0.55 * dens
                    shed += dens * 2
                }
            }
        }

        // Vaseline, smeared along stretches of the tape in streaks.
        if t.vaseline > 0 {
            let (sx, fx) = cell(p, 600)
            if uni(s, 71, sx, 0) < 0.2 + 0.8 * t.vaseline {
                let a = 0.4 * uni(s, 72, sx, 0)
                let b = 0.6 + 0.4 * uni(s, 73, sx, 0)
                let taper = smoothstep(a, a + 0.05, fx) * smoothstep(b, b - 0.05, fx)
                if taper > 0 {
                    let (c8, f8) = cell(p, 80)
                    let yy = y * 5
                    let cy = Int32(yy.rounded(.down))
                    let streak = powf(noise2(s, 74, c8, f8, cy, yy - Float(cy)), 1.5)
                    film = t.vaseline * 1.8 * (0.25 + 0.75 * streak) * taper
                }
            }
        }

        return TapePoint(lift: lift, film: film, output: max(0, out), shed: shed)
    }

    /// A crease the given field's track crosses: how far along the track (mm)
    /// and by how much the fold shortens it (µm).
    public struct Fold: Equatable {
        public var along: Double
        public var width: Double
        public var shortening: Double
    }

    /// The creases track `field` crosses, in order along it. The fold
    /// shortens the tape there, so everything the head reads after a crease
    /// arrives early — a timing jump for the TV to chase.
    public static func folds(field: Int64, _ t: TapeParams, format: TapeFormat = .sp) -> [Fold] {
        guard t.creases > 0 else { return [] }
        let s = t.seed
        let start = TapeGeometry.trackOrigin(field: field, format: format)
        let lo = Int32((start * 10 / 400).rounded(.down)) - 1
        let hi = Int32(((start + TapeGeometry.trackLength) * 10 / 400).rounded(.down)) + 1
        let c = cos(TapeGeometry.angle), sn = sin(TapeGeometry.angle)
        var out: [Fold] = []
        for ci in lo...hi {
            guard uni(s, 41, ci, 0) < t.creases * 0.9 else { continue }
            let xc = (Double(ci) + Double(uni(s, 42, ci, 0))) * 40
            let slant = Double(tanf((uni(s, 43, ci, 0) - 0.5) * 0.7))
            let fromBottom = uni(s, 44, ci, 0) < 0.5
            let extent = TapeGeometry.width * (0.25 + 0.75 * Double(uni(s, 45, ci, 0)))
            let w = 0.3 + 2.7 * pow(Double(uni(s, 46, ci, 0)), 1.5)
            let peak = (0.5 + 3.5 * pow(Double(uni(s, 47, ci, 0)), 1.5)) * (0.4 + 0.6 * Double(t.creases))
            // The crease is the line x = xc + yy·slant (yy from its edge);
            // the track is x = start + a·cos, y = trackStart + a·sin.
            let y0 = TapeGeometry.trackStart
            let a: Double
            if fromBottom {
                a = (xc + y0 * slant - start) / (c - sn * slant)
            } else {
                a = (xc + (TapeGeometry.width - y0) * slant - start) / (c + sn * slant)
            }
            guard a >= 0, a <= TapeGeometry.trackLength else { continue }
            let y = y0 + a * sn
            let yy = fromBottom ? y : TapeGeometry.width - y
            guard yy < extent else { continue }
            let reach = Double(smoothstep(Float(extent), Float(extent) * 0.8, Float(yy)))
            out.append(Fold(along: a, width: w, shortening: 4 * peak * reach))
        }
        return out.sorted { $0.along < $1.along }
    }
}
