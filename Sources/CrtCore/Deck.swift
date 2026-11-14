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
        wear = u("head_wear")
        dirt = u("head_dirt")
        buildup = u("dirt_buildup")
        mismatch = u("head_mismatch")
    }

    /// Each head's wear: mismatch moves them apart, mostly by ageing head 1.
    public func wear(_ h: Int) -> Float {
        h == 0 ? wear * (1 - 0.4 * mismatch) : min(1, wear * (1 + 0.4 * mismatch) + 0.25 * mismatch)
    }

    /// Spacing a worn head's lost tip penetration adds, µm.
    public func wearSpacing(_ h: Int) -> Float { 0.3 * wear(h) }

    /// Read efficiency (a worn core, and the weaker of a mismatched pair).
    public func efficiency(_ h: Int) -> Float {
        powf(10, -(wear(h) * 10 + (h == 1 ? mismatch * 3 : 0)) / 20)
    }

    /// The head's gap length, µm: 0.3 new, eroding longer with wear.
    public func gap(_ h: Int) -> Float { 0.3 + 0.35 * wear(h) }

    /// Dirt baked onto each head (µm of spacing) — there until cleaned,
    /// unlike the clogs that come and go. The two heads carry different
    /// amounts.
    public func baselineDirt(_ h: Int, seed: UInt32) -> Float {
        let share: Float = h == 0 ? 1.2 : 0.5 + 0.8 * TapeSurface.uni(seed, 90, 1, 0)
        return dirt * 0.5 * share
    }

    /// µm of debris a head collects per second per unit of shedding.
    var pickup: Float { 0.02 + 1.2 * buildup * buildup }
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
    /// The last field stepped through (the heads' state is after it).
    public private(set) var field: Int64 = 0
    private(set) var heads: [HeadState] = []
    /// Head states entering each of the last few fields.
    private var history: [(field: Int64, heads: [HeadState])] = []
    private static let historyCap = 12

    public init(settings: GlitchSettings) {
        tape = TapeParams(settings)
        deck = DeckParams(settings)
    }

    public func update(_ settings: GlitchSettings) {
        tape = TapeParams(settings)
        deck = DeckParams(settings)
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
            let p = TapeSurface.at(TapeGeometry.point(field: f, along: along), tape, detail: false)
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
        s.debris += deck.pickup * shed * dt - s.debris * 0.5 * dt
        // A chunk lodges in the gap: a clog that takes a while to wipe off.
        if TapeSurface.uni(seed, 81, field, era) < min(0.25, deck.pickup * shed * 0.03) {
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
