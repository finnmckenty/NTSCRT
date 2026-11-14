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
    public static func trackOrigin(field: Int64) -> Double {
        Double(field) * advancePerField
    }

    /// The tape point `along` mm up the track of field `field`, offset
    /// `across` mm sideways (toward the top edge).
    public static func point(field: Int64, along: Double, across: Double = 0) -> TapePosition {
        let x = trackOrigin(field: field) + along * cos(angle) - across * sin(angle)
        let y = trackStart + along * sin(angle) + across * cos(angle)
        return TapePosition(x: x, y: y)
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

    public init(_ s: GlitchSettings) {
        seed = UInt32(truncatingIfNeeded: Int(s["tape_seed"].rounded()) &* 7919 &+ 17)
        func u(_ k: String) -> Float { Float(min(1, max(0, s[k]))) }
        wear = u("tape_wear")
        dropouts = u("tape_dropouts")
        scratches = u("tape_scratches")
        creases = u("tape_creases")
        edge = u("tape_edge_damage")
        mold = u("tape_mold")
        vaseline = u("tape_vaseline")
    }

    /// Remanent magnetization relative to a new tape: wear loses up to 7 dB.
    public var remanence: Float { powf(10, -wear * 7 / 20) }
    /// Surface roughness as head-to-tape spacing, µm.
    public var roughness: Float { 0.015 + 0.06 * wear }
    /// Chance that a 0.1 mm square holds a pinhole.
    public var pinholeChance: Float { (0.05 + 6 * dropouts + 2 * wear) * 0.01 }
    /// Chance that a 1 mm square holds a flake of missing coating.
    public var flakeChance: Float { 0.001 + 0.12 * dropouts + 0.04 * wear + 0.06 * mold }
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
    /// or to what the heads pick up.
    public static func at(_ p: TapePosition, _ t: TapeParams, detail: Bool = true) -> TapePoint {
        let s = t.seed
        let y = p.y
        var lift = t.roughness
        var out = t.remanence
        var film: Float = 0
        var shed: Float = 0.02 * t.wear

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

        // Flakes: patches of coating 40–320 µm across gone, shedding.
        if t.flakeChance > 0 {
            let (cx, _) = cell(p, 10)
            let cy = Int32(y.rounded(.down))
            for j in -1...1 {
                for i in -1...1 {
                    let ci = cx &+ Int32(i), cj = cy &+ Int32(j)
                    guard uni(s, 21, ci, cj) < t.flakeChance else { continue }
                    let ddx = dx(p, cell: ci, q: 10, frac: uni(s, 22, ci, cj)) * 0.1
                    let ddy = Float(cj) + uni(s, 23, ci, cj) - y
                    let u = uni(s, 24, ci, cj)
                    let r = 0.04 * powf(8, u * u)
                    let e = 0.6 + 0.8 * uni(s, 25, ci, cj)
                    let d = ((ddx / e) * (ddx / e) + (ddy * e) * (ddy * e)).squareRoot()
                    if d < r * 1.5 {
                        out *= smoothstep(r * 0.8, r, d)
                        shed += 0.5 * (1 - smoothstep(r, r * 1.5, d))
                    }
                }
            }
        }

        // Lengthwise scratches from guides: 6–50 µm wide, along a stretch.
        if detail && t.scratches > 0 {
            let lane = Int32((y * 20).rounded(.down))
            let (sx, fx) = cell(p, 3000)
            for l in -1...1 {
                let li = lane &+ Int32(l)
                guard uni(s, 31, li, sx) < t.scratches * 0.06 else { continue }
                let a = uni(s, 32, li, sx), b = uni(s, 33, li, sx)
                guard fx >= min(a, b) * 0.6, fx <= 0.4 + max(a, b) * 0.6 else { continue }
                let yc = (Float(li) + 0.2 + 0.6 * uni(s, 34, li, sx)) * 0.05
                let w = 0.006 + 0.045 * powf(uni(s, 35, li, sx), 2)
                if abs(y - yc) < w * 0.5 {
                    out *= 0.25 + 0.5 * uni(s, 36, li, sx)
                    lift += 0.04
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
                let w = 0.12 + 0.9 * uni(s, 46, ci, 0)
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
                    film = t.vaseline * 1.5 * (0.3 + 0.7 * streak) * taper
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
    public static func folds(field: Int64, _ t: TapeParams) -> [Fold] {
        guard t.creases > 0 else { return [] }
        let s = t.seed
        let start = TapeGeometry.trackOrigin(field: field)
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
            let w = 0.12 + 0.9 * Double(uni(s, 46, ci, 0))
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
