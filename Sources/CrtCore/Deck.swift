import Foundation

/// The deck's two video heads as the simulation uses them, from the Deck
/// knobs. Head 0 plays even fields, head 1 odd ones.
public struct DeckParams: Equatable {
    public var wear: Float
    public var dirt: Float
    public var buildup: Float
    public var mismatch: Float

    public init(_ s: GlitchSettings) {
        func u(_ k: String) -> Float { Float(min(1, max(0, s[k]))) }
        // (The slider's taper: wear's effects grow faster than the wear, so
        // the lower half of the travel gets a little more of it.)
        wear = powf(u("head_wear"), 0.85)
        // (Tapered a little, so three quarters of the knob gives a third of
        // its full effect: the picture breaks up late, where the dirt
        // reaches the FM threshold.)
        dirt = powf(u("head_dirt"), 0.88)
        buildup = u("dirt_buildup")
        mismatch = u("head_mismatch")
    }

    /// Each head's wear: mismatch moves them apart, mostly by ageing head 1.
    public func wear(_ h: Int) -> Float {
        h == 0 ? wear * (1 - 0.4 * mismatch) : min(1, wear * (1 + 0.4 * mismatch) + 0.25 * mismatch)
    }

    /// Spacing a worn head's lost tip penetration adds on average, µm, at
    /// full wear — most of what wear costs. A new tip stands 0.12–0.16 mm
    /// proud of the drum and presses a dent into the tape; worn to a third
    /// of that it no longer holds the tape against itself.
    static let wearSpacingUM: Float = 0.33
    /// The rest: output lost whatever the wavelength (a shallower core, less
    /// inductance), dB at full wear. Measured decks give ~4 dB where the
    /// picture starts to suffer.
    static let wearLossDB: Float = 5
    /// And the gap's edges chip: 0.3 µm new, this much longer at full wear.
    static let wearGapUM: Float = 0.3

    /// The worn tip's spacing on average, µm.
    public func wearSpacing(_ h: Int) -> Float { Self.wearSpacingUM * wear(h) }

    /// The worn tip's spacing at one moment, µm: where the head is along
    /// its sweep of track `field` (`along` mm) on cassette `seed`.
    public func wearSpacing(_ h: Int, field: Int64, along: Double, seed: UInt32) -> Float {
        let w = wearSpacing(h)
        return w > 0 ? w * Self.contact(field: field, along: along, seed: seed) : 0
    }

    /// How far a worn tip stands off the tape at one moment, against its
    /// average (1). A tip that no longer dents the tape rides on whatever
    /// the tape is doing: it meets the tape late and leaves it early (the
    /// top and bottom of the picture), ripples in the tape's wrap pass under
    /// it (bands that drift through the picture), and the tension holding
    /// the tape on wanders (the whole picture comes and goes over a second
    /// or so). Both heads sweep the same tape, so they share it. Like every
    /// random thing here it is a hash of the cassette's seed and the time,
    /// so any moment plays the same again. How fast and how far it moves is
    /// a choice, not a measurement: repair notes only say that a worn
    /// head's noise comes in bands that come and go in a cycle.
    static func contact(field: Int64, along: Double, seed: UInt32) -> Float {
        let x = min(1, max(0, along / TapeGeometry.trackLength))
        let t = Double(field) + x                       // time, in fields
        /// Smooth noise (−1…1) over a place along the sweep and the time.
        func noise(_ k: UInt32, across a: Double, per: Double) -> Float {
            let b = t / per
            let ai = a.rounded(.down), bi = b.rounded(.down)
            return 2 * TapeSurface.noise2(seed, k, Int32(truncatingIfNeeded: Int64(ai)), Float(a - ai),
                                          Int32(truncatingIfNeeded: Int64(bi)), Float(b - bi)) - 1
        }
        let ends = Float(exp(-x / 0.07) + 0.7 * exp(-(1 - x) / 0.05))
        let tension = noise(95, across: 0, per: 45)
        let ripple = noise(96, across: 3 * x + 0.013 * t, per: 25)
        let flutter = noise(97, across: 11 * x - 0.031 * t, per: 9)
        return max(0.15, 1 + contactDepth * (0.5 * ends + 0.35 * tension + 0.6 * ripple + 0.25 * flutter))
    }
    static let contactDepth: Float = 0.7

    /// Read efficiency (a worn core, and the weaker of a mismatched pair).
    public func efficiency(_ h: Int) -> Float {
        powf(10, -(wear(h) * Self.wearLossDB + (h == 1 ? mismatch * 3 : 0)) / 20)
    }

    /// The head's gap length, µm: 0.3 new, eroding longer with wear.
    public func gap(_ h: Int) -> Float { 0.3 + Self.wearGapUM * wear(h) }

    /// How much the deck's color path raises the color-under so that tape
    /// wear and head wear don't fade the color. It undoes exactly what they
    /// take from the 629 kHz carrier: the tape's lost remanence and
    /// roughness, the worn head's efficiency, tip spacing and gap. People
    /// turn wear up for a worn picture, not a black-and-white one. The
    /// picture keeps its worn signal; flaws, scratches, creases and edge
    /// damage still take the color where they are. A mismatched pair's
    /// extra wear on head 1 isn't undone.
    public func colorBoost(_ h: Int, tape: TapeParams) -> Float {
        let mhz = VcrChannel.colorUnderMHz
        let rough = VcrChannel.channelGain(mhz: mhz, spacing: Double(0.1 * tape.wear), gap: 0.3)
        let new = VcrChannel.channelGain(mhz: mhz, spacing: 0, gap: 0.3)
        let lost = tape.remanence * Float(rough / new)
        return colorNoise(h) / max(lost, 1e-3)
    }

    /// The head's own share of that boost, which the head's noise rides up
    /// with — as it does when a deck's color control (ACC) turns up a weak
    /// color signal: a worn head's color keeps its strength and gets
    /// noisier. (The tape's share is raised against the same head noise, as
    /// if the tape were new.)
    public func colorNoise(_ h: Int) -> Float {
        let w = min(wear(h), wear)
        let mhz = VcrChannel.colorUnderMHz
        let worn = VcrChannel.channelGain(mhz: mhz, spacing: Double(Self.wearSpacingUM * w),
                                          gap: Double(0.3 + Self.wearGapUM * w))
        let new = VcrChannel.channelGain(mhz: mhz, spacing: 0, gap: 0.3)
        return 1 / max(powf(10, -w * Self.wearLossDB / 20) * Float(worn / new), 1e-3)
    }

    /// Dirt baked onto each head (µm of spacing) — there until cleaned,
    /// unlike the clogs that come and go. The two heads carry different
    /// amounts.
    public func baselineDirt(_ h: Int, seed: UInt32) -> Float {
        let share: Float = h == 0 ? 1.2 : 0.5 + 0.8 * TapeSurface.uni(seed, 90, 1, 0)
        return dirt * 0.5 * share
    }

    /// That dirt as the head carries it through field `field`: the layer
    /// shifts as the tape drags over it — packs down, lifts at an edge — so
    /// it holds the head off a little more or less from second to second.
    /// Each head's shifts on its own, so the two drift apart and back (the
    /// difference between alternate fields breathes); within a sweep it is
    /// one thing, since it rides on the head. How far and how fast is a
    /// choice.
    public func baselineDirt(_ h: Int, seed: UInt32, field: Int64) -> Float {
        let d = baselineDirt(h, seed: seed)
        return d > 0 ? d * Self.dirtShift(h, field: field, seed: seed) : 0
    }

    static func dirtShift(_ h: Int, field: Int64, seed: UInt32) -> Float {
        func noise(_ k: UInt32, per: Double) -> Float {
            let b = Double(field) / per, bi = b.rounded(.down)
            return 2 * TapeSurface.noise1(seed, k + UInt32(h), Int32(truncatingIfNeeded: Int64(bi)), Float(b - bi)) - 1
        }
        return 1 + 0.15 * noise(98, per: 90) + 0.06 * noise(100, per: 16)
    }

    /// µm of debris head `h` collects per second per unit of shedding: next
    /// to nothing on a deck just cleaned, rising evenly along the knob (half
    /// way, about a third of full). A worn head collects more: its chipped
    /// gap and flattened tip hold what a new one sheds (repair notes: heads
    /// clog more easily as they near the end of their life) — twice as much
    /// when fully worn.
    func pickup(_ h: Int) -> Float { (0.02 + 1.2 * powf(buildup, 1.5)) * (1 + wear(h)) }
}

/// What one head carries at a moment, beyond its baked-on dirt.
public struct HeadState: Equatable {
    /// Debris lodged on it as the tape played, µm of extra spacing.
    public var debris: Float
    /// A greasy film picked up from the tape (Vaseline), µm.
    public var grease: Float
}

/// The heads' condition over time. A head touches the tape only while it
/// plays its own field; in that time it picks up what the tape sheds there
/// (more on a moldy or flaking stretch, more on a deck that's never been
/// cleaned), a chunk now and then lodges in it, and now and then debris
/// knocks loose. A Vaseline film transfers quickly and wipes off slowly.
///
/// Like the receiver, the state depends only on the knobs over time and the
/// seed — every random event is a hash of its field — so any moment can be
/// reproduced by playing from the start.
public final class DeckSimulator {
    public private(set) var tape: TapeParams
    public private(set) var deck: DeckParams
    public private(set) var format: TapeFormat
    /// The last field stepped through (the heads' state is after it).
    public private(set) var field: Int64 = 0
    private(set) var heads: [HeadState] = []
    /// Head states entering each of the last few fields.
    private var history: [(field: Int64, heads: [HeadState])] = []
    private static let historyCap = 12

    public init(settings: GlitchSettings) {
        tape = TapeParams(settings)
        deck = DeckParams(settings)
        format = TapeFormat(settings)
    }

    public func update(_ settings: GlitchSettings) {
        tape = TapeParams(settings)
        deck = DeckParams(settings)
        format = TapeFormat(settings)
    }

    /// Back to the start of play, at `field`.
    public func reset(atField f: Int64) {
        field = f - 1
        heads = [HeadState(debris: 0, grease: 0), HeadState(debris: 0, grease: 0)]
        history = []
    }

    public struct Snapshot {
        fileprivate let field: Int64
        fileprivate let heads: [HeadState]
        fileprivate let history: [(field: Int64, heads: [HeadState])]
    }

    public func snapshot() -> Snapshot { Snapshot(field: field, heads: heads, history: history) }

    public func restore(_ s: Snapshot) {
        field = s.field; heads = s.heads; history = s.history
    }

    /// Play on through field `f`.
    public func advance(toField f: Int64) {
        if heads.isEmpty { reset(atField: f) }
        while field < f {
            let next = field + 1
            history.append((next, heads))
            if history.count > Self.historyCap { history.removeFirst() }
            step(next)
            field = next
        }
    }

    /// The heads entering field `f` (the most recent state for fields not
    /// yet reached, the oldest kept for ones long past).
    public func heads(forField f: Int64) -> [HeadState] {
        if f > field { return heads }
        if let h = history.last(where: { $0.field == f }) { return h.heads }
        return history.first?.heads ?? heads
    }

    /// Field `f`, played by head f mod 2.
    private func step(_ f: Int64) {
        let h = Int(posmod(f, 2))
        let dt: Float = Float(1 / NTSCTiming.fieldRate)
        // What this stretch of tape sheds, and its film, along the track.
        var shed: Float = 0, film: Float = 0
        let n = 12
        for i in 0..<n {
            let along = (Double(i) + 0.5) / Double(n) * TapeGeometry.trackLength
            let p = TapeSurface.at(TapeGeometry.point(field: f, along: along, format: format), tape, detail: false)
            shed += p.shed
            film += p.film
        }
        shed /= Float(n); film /= Float(n)

        var s = heads[h]
        let seed = tape.seed
        let field = Int32(truncatingIfNeeded: f), era = Int32(truncatingIfNeeded: f >> 31)
        // Steady pickup, wiped off again by the tape over a couple of
        // seconds of contact — so a shedding tape keeps the heads at a level
        // that rises and falls with what is passing.
        s.debris += deck.pickup(h) * shed * dt - s.debris * 0.5 * dt
        // A chunk lodges in the gap: a clog that takes a while to wipe off.
        if TapeSurface.uni(seed, 81, field, era) < min(0.25, deck.pickup(h) * shed * 0.03) {
            s.debris += 0.15 + 0.65 * TapeSurface.uni(seed, 82, field, era)
        }
        // Debris knocks loose, likelier the more there is.
        if TapeSurface.uni(seed, 83, field, era) < 0.0005 + 0.004 * s.debris * s.debris {
            s.debris *= 0.25 * TapeSurface.uni(seed, 84, field, era)
        }
        s.debris = max(0, min(6, s.debris))
        s.grease += (film - s.grease) * (film > s.grease ? 0.2 : 0.003)
        heads[h] = s
    }
}
