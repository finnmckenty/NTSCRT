import Foundation

/// One control of the glitch stage. The stage simulates a TV receiver and a
/// VCR playing a tape, so every control is a knob that existed on one of them
/// or a physical condition of the tape or the signal — glitches come out of
/// the simulated circuits' and materials' response, never from drawing them.
public struct GlitchParam: Identifiable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        /// The TV and the signal reaching it (the Glitch panel).
        case reception = "Reception"
        /// The cassette's condition (the VCR panel).
        case tape = "Tape"
        /// The deck: its heads and transport (the VCR panel).
        case deck = "Deck"
    }
    public enum Kind: Sendable, Equatable {
        /// `percent` controls are shown as 0–100 (or ±100); `unit` labels
        /// the rest (µs).
        case slider(min: Double, max: Double, percent: Bool, unit: String)
        case toggle
        /// A whole number that picks one of endlessly many variations (which
        /// cassette); shown as a "new one" button, never interpolated.
        case seed
    }

    public let id: String
    public let label: String
    public let group: Group
    public let kind: Kind
    public let defaultValue: Double
    public let help: String

    public var isToggle: Bool { kind == .toggle }
    /// Stepped, not blended, between keyframes.
    public var isDiscrete: Bool { kind == .toggle || kind == .seed }

    /// The VCR panel's on/off switch, kept with the knobs so it is saved,
    /// keyframed and exported along with them.
    public static let vcrID = "vcr"

    /// Defaults describe a healthy set on a clean signal, and a new tape in a
    /// clean deck: enabling the stage changes nothing until a knob is turned
    /// (the VCR itself, once switched on, always plays like VHS).
    public static let all: [GlitchParam] = reception + vcr

    static let reception: [GlitchParam] = [
        GlitchParam(
            id: "signal_strength", label: "Signal strength", group: .reception,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 1,
            help: "Antenna signal level. Lowering it brings snow first, then flickering and lost color as the color burst drowns, then broken sync as the sync pulses do — the order a real set fails in."),
        GlitchParam(
            id: "vertical_hold", label: "Vertical hold", group: .reception,
            kind: .slider(min: -1, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "The vertical oscillator's free-running speed. Near the center the sync pulses pull it into lock; past the lock range the picture rolls, with the blanking bar crossing the screen."),
        GlitchParam(
            id: "horizontal_hold", label: "Horizontal hold", group: .reception,
            kind: .slider(min: -1, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "The horizontal oscillator's free-running speed. Off center the picture slides sideways as the AFC strains to hold it; further and lock breaks — the picture tears into diagonal bands and the color goes wild."),
        GlitchParam(
            id: "afc_speed", label: "AFC response", group: .reception,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0.5,
            help: "How quickly the TV's horizontal AFC follows timing changes. Slow sets ride out noise but bend at the top of the picture on VCR playback (flagging); fast ones track tape timing but jitter in noise."),
        GlitchParam(
            id: "brightness", label: "Brightness", group: .reception,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Raises the picture tube's black level, as turning up a TV's brightness did. The blanking intervals and sync pulses become visible when the picture rolls or tears."),
        GlitchParam(
            id: "ghost_level", label: "Ghost", group: .reception,
            kind: .slider(min: -1, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "A reflected copy of the signal arriving late (multipath). Negative values invert it, as reflections often did. Its color shifts with the delay, because the delayed color carrier arrives at a different phase."),
        GlitchParam(
            id: "ghost_delay", label: "Ghost delay", group: .reception,
            kind: .slider(min: 0.2, max: 12, percent: false, unit: "µs"), defaultValue: 2,
            help: "How late the reflection arrives. 1 µs is about 2% of the picture width — a reflection path roughly 300 m longer than the direct one."),
        GlitchParam(
            id: "hum", label: "Hum", group: .reception,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Mains hum leaking into the video: light and dark bars that drift slowly up the picture (60 Hz hum against the 59.94 Hz color field rate), bending the picture where the sync separator is pulled off."),
        GlitchParam(
            id: "closed_captions", label: "Caption data", group: .reception,
            kind: .toggle, defaultValue: 1,
            help: "Line 21 carries closed-caption data — the row of dashes visible in the blanking bar when the picture rolls."),
    ]

    static let vcr: [GlitchParam] = [
        GlitchParam(
            id: vcrID, label: "VCR", group: .deck, kind: .toggle, defaultValue: 0,
            help: "Play the picture from a simulated VHS tape: it is recorded as an FM signal on the tape's slanted tracks and read back by the deck's two spinning heads, through everything the tape and heads are doing to it."),

        // The tape.
        GlitchParam(
            id: "tape_seed", label: "Cassette", group: .tape, kind: .seed, defaultValue: 1,
            help: "Which cassette: another one has the same condition but its own flaws in its own places."),
        GlitchParam(
            id: "tape_wear", label: "Wear", group: .tape,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Age and plays. The magnetic coating weakens and roughens, so the heads read a weaker signal over a slightly larger gap — noisier pictures, then sparkles where the signal sinks to the FM threshold — and pinholes appear in the oxide."),
        GlitchParam(
            id: "tape_dropouts", label: "Oxide flaws", group: .tape,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Pinholes and flakes missing from the magnetic coating. A flaw wider than one 58 µm track shows in the same place for a few fields in a row; one smaller than a track only weakens the signal, and is seen only when the signal is weak already."),
        GlitchParam(
            id: "tape_scratches", label: "Scratches", group: .tape,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Scratches along the tape from worn guides. Height across the tape is height in the picture, so a lengthwise scratch is a streak at the same height in every field."),
        GlitchParam(
            id: "tape_creases", label: "Creases", group: .tape,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Folds across the tape. The heads cross each one a little earlier every field, so it sweeps up through the picture as a band of noise over a few seconds; the fold also shortens the track, a timing jump the TV has to chase."),
        GlitchParam(
            id: "tape_edge_damage", label: "Edge damage", group: .tape,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Crinkled tape edges, from a deck that chewed it. The tracks start at the bottom edge and end at the top, so the damage lifts the tape off the heads at the top and bottom of the picture."),
        GlitchParam(
            id: "tape_mold", label: "Mold", group: .tape,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Fungus colonies, thickest near the edges where it grows in the wound pack. Each one lifts the tape off the heads and eats into the coating, and it sheds — what it sheds collects on the heads."),
        GlitchParam(
            id: "tape_vaseline", label: "Vaseline", group: .tape,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "A film smeared on the tape, holding the heads off it. Spacing costs the short-wavelength picture signal far more than the long-wavelength color, so the picture breaks into noise while color survives and smears. It rubs off onto the heads, too."),

        // The deck.
        GlitchParam(
            id: "head_wear", label: "Head wear", group: .deck,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Worn heads stand less proud of the drum, so they press into the tape less, and their gaps erode wider. Both lose the top of the signal first: black streaks trail bright edges, then the picture gets noisy."),
        GlitchParam(
            id: "head_dirt", label: "Head dirt", group: .deck,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Debris already on the heads when play starts. It holds them off the tape; each head carries its own, so one can be clogged while the other is clear — every other field fails."),
        GlitchParam(
            id: "dirt_buildup", label: "Dirt buildup", group: .deck,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "How readily the heads collect what the tape sheds — low for a deck that's had a head-cleaning tape, high for one that never has. Shedding tapes (mold, wear, flaws) clog it as they play; clogs sometimes knock loose."),
        GlitchParam(
            id: "head_mismatch", label: "Head mismatch", group: .deck,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "How unevenly the two heads have aged: one reads a weaker signal than the other, and since they take turns, field by field, the picture flickers between them."),
        GlitchParam(
            id: "head_switch", label: "Head switching", group: .deck,
            kind: .slider(min: 0, max: 8, percent: false, unit: "µs"), defaultValue: 0,
            help: "How far the two heads are from exactly opposite on the drum, as a timing jump when the deck changes heads just before vertical sync. The bottom lines jump sideways and the TV's AFC chases the jump into the top of the next field — the bend called flagging."),
        GlitchParam(
            id: "dropout_compensation", label: "Dropout compensation", group: .deck,
            kind: .toggle, defaultValue: 1,
            help: "The deck watches the signal coming off the heads and, where it drops out, repeats the picture from the line before. On, dropouts become short smears of the line above; off, they show as the demodulator's streaks."),
        GlitchParam(
            id: "timebase_jitter", label: "Time-base jitter", group: .deck,
            kind: .slider(min: 0, max: 3, percent: false, unit: "µs"), defaultValue: 0,
            help: "Tape stretch and transport flutter. The TV's AFC follows the slow wander; the fast jitter shows as ragged lines."),
        GlitchParam(
            id: "tracking", label: "Tracking error", group: .deck,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "The heads drifting off the recorded tracks. Well tracked, the stretch where they cross to the next track rests in the vertical interval, out of sight; as the error grows the heads read less and less of their track there, and the noise band climbs into the picture."),
        GlitchParam(
            id: "search_speed", label: "Search", group: .deck,
            kind: .slider(min: 1, max: 9, percent: false, unit: "×"), defaultValue: 1,
            help: "Fast-forward picture search. The spinning heads cross from track to track, reading noise between them: one fewer noise bar than the speed, drifting as the tracking phase slides, with the picture jumping at each crossing."),
    ]

    public static let byID: [String: GlitchParam] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static var defaultValues: [String: Double] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.defaultValue) })
    }

    /// The controls a panel shows for a group (the VCR switch lives in the
    /// VCR panel's header instead).
    public static func controls(in group: Group) -> [GlitchParam] {
        all.filter { $0.group == group && $0.id != vcrID }
    }
}

/// A named condition for the VCR panel's Tape and Deck pickers: a starting
/// point for that group's knobs, which can then be adjusted.
public struct VcrCondition: Identifiable, Sendable {
    public let name: String
    public let help: String
    public let values: [String: Double]
    public var id: String { name }

    /// The knobs a picker sets: a tape's condition, or a deck's heads (not
    /// the transport knobs, nor dropout compensation).
    public static let tapeKeys = ["tape_wear", "tape_dropouts", "tape_scratches", "tape_creases",
                                  "tape_edge_damage", "tape_mold", "tape_vaseline"]
    public static let deckKeys = ["head_wear", "head_dirt", "dirt_buildup", "head_mismatch"]

    public static let tapes: [VcrCondition] = [
        VcrCondition(name: "Brand new", help: "Fresh out of the shrink-wrap.",
                     values: [:]),
        VcrCondition(name: "Used", help: "A rental: played a few dozen times.",
                     values: ["tape_wear": 0.3, "tape_dropouts": 0.15, "tape_scratches": 0.1]),
        VcrCondition(name: "Worn out", help: "Played to death in a garage for twenty years.",
                     values: ["tape_wear": 0.75, "tape_dropouts": 0.5, "tape_scratches": 0.45,
                              "tape_creases": 0.15, "tape_edge_damage": 0.2]),
        VcrCondition(name: "Moldy", help: "Stored somewhere damp.",
                     values: ["tape_wear": 0.5, "tape_dropouts": 0.35, "tape_mold": 0.7,
                              "tape_edge_damage": 0.1]),
        VcrCondition(name: "Vaselined", help: "Smeared on purpose.",
                     values: ["tape_wear": 0.2, "tape_vaseline": 0.6]),
        VcrCondition(name: "Chewed", help: "Eaten by a deck and wound back by hand.",
                     values: ["tape_wear": 0.4, "tape_dropouts": 0.3, "tape_scratches": 0.4,
                              "tape_creases": 0.7, "tape_edge_damage": 0.7]),
    ]

    public static let decks: [VcrCondition] = [
        VcrCondition(name: "Clean heads", help: "Freshly cleaned with a head-cleaning tape.",
                     values: [:]),
        VcrCondition(name: "Dirty heads", help: "Never cleaned: carries some debris, and picks up more.",
                     values: ["head_wear": 0.2, "head_dirt": 0.45, "dirt_buildup": 0.6,
                              "head_mismatch": 0.3]),
        VcrCondition(name: "Worn heads", help: "Thousands of hours on the drum.",
                     values: ["head_wear": 0.7, "head_dirt": 0.05, "dirt_buildup": 0.2,
                              "head_mismatch": 0.35]),
        VcrCondition(name: "Neglected", help: "Worn, filthy, and still in use.",
                     values: ["head_wear": 0.6, "head_dirt": 0.7, "dirt_buildup": 0.9,
                              "head_mismatch": 0.5]),
    ]

    /// The condition whose values `values` match exactly, if any.
    public static func matching(_ list: [VcrCondition], keys: [String],
                                in values: [String: Double]) -> VcrCondition? {
        list.first { c in
            keys.allSatisfy { k in
                abs((values[k] ?? GlitchParam.byID[k]?.defaultValue ?? 0)
                    - (c.values[k] ?? GlitchParam.byID[k]?.defaultValue ?? 0)) < 1e-6
            }
        }
    }

    /// `values` with this condition applied to `keys`.
    public func applied(to values: [String: Double], keys: [String]) -> [String: Double] {
        var out = values
        for k in keys { out[k] = self.values[k] ?? GlitchParam.byID[k]?.defaultValue ?? 0 }
        return out
    }
}

/// The glitch stage's settings for one moment: every knob's value, keyed by
/// `GlitchParam.id` (the same flat form presets and keyframes store).
public struct GlitchSettings: Equatable, Sendable {
    public var values: [String: Double]

    public init(values: [String: Double] = GlitchParam.defaultValues) {
        // Missing keys (older presets) fall back to the healthy defaults.
        self.values = GlitchParam.defaultValues.merging(values) { _, new in new }
    }

    public subscript(_ id: String) -> Double {
        values[id] ?? GlitchParam.byID[id]?.defaultValue ?? 0
    }

    public func flag(_ id: String) -> Bool { self[id] >= 0.5 }

    /// Whether the VCR plays the picture (its panel is switched on).
    public var vcr: Bool { flag(GlitchParam.vcrID) }

    /// These settings with every Reception knob back to healthy — the
    /// stage's input when only the VCR panel is on.
    public var receptionHealthy: GlitchSettings {
        var v = values
        for p in GlitchParam.reception { v[p.id] = p.defaultValue }
        return GlitchSettings(values: v)
    }

    /// These settings with the VCR switched off.
    public var withoutVCR: GlitchSettings {
        var v = values
        v[GlitchParam.vcrID] = 0
        return GlitchSettings(values: v)
    }

    /// Knobs that change the simulation's evolving state: anything touching
    /// sync, timing or signal level, and everything about the tape and deck
    /// (the tape decides where sync is lost; the heads collect dirt as it
    /// plays). The rest — ghost, brightness, caption data, dropout
    /// compensation — are applied when the field is drawn, so changing them
    /// never needs the history re-run.
    public static let timingIDs: Set<String> = Set(
        ["signal_strength", "vertical_hold", "horizontal_hold", "afc_speed", "hum"]
        + GlitchParam.vcr.map(\.id).filter { $0 != "dropout_compensation" })

    public var timing: [String: Double] { values.filter { Self.timingIDs.contains($0.key) } }

    /// Values saved before the VCR panel existed, in today's terms. The old
    /// Tape knobs were effects drawn on the signal; their nearest physical
    /// causes are a flawed or creased tape and dirty heads. A look that used
    /// any of them gets the VCR switched on (it was playing a tape). Values
    /// that already have the VCR key are returned unchanged.
    public static func migrated(_ values: [String: Double]) -> [String: Double] {
        guard values[GlitchParam.vcrID] == nil else { return values }
        var v = values
        let legacy = ["head_clog", "crinkle", "dropouts"]
        let kept = ["head_switch", "timebase_jitter", "tracking", "search_speed"]
        var usedTape = false
        if let c = v.removeValue(forKey: "head_clog"), c > 0 {
            v["head_dirt"] = min(1, c * 0.9)
            usedTape = true
        }
        if let c = v.removeValue(forKey: "crinkle"), c > 0 {
            v["tape_creases"] = min(1, c)
            usedTape = true
        }
        if let d = v.removeValue(forKey: "dropouts"), d > 0 {
            v["tape_dropouts"] = min(1, d)
            usedTape = true
        }
        for k in legacy { v.removeValue(forKey: k) }
        for k in kept {
            if let x = v[k], let p = GlitchParam.byID[k], abs(x - p.defaultValue) > 1e-9 { usedTape = true }
        }
        v[GlitchParam.vcrID] = usedTape ? 1 : 0
        return v
    }
}
