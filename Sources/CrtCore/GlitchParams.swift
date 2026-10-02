import Foundation

/// One control of the glitch stage. The stage simulates a TV receiver and a
/// VCR transport, so every control is a knob that existed on one of them (or
/// a physical condition of the signal) — glitches come out of the simulated
/// circuits' response, never from drawing them.
public struct GlitchParam: Identifiable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case reception = "Reception"
        case tape = "Tape"
    }
    public enum Kind: Sendable, Equatable {
        /// `percent` controls are shown as 0–100 (or ±100); `unit` labels
        /// the rest (µs).
        case slider(min: Double, max: Double, percent: Bool, unit: String)
        case toggle
    }

    public let id: String
    public let label: String
    public let group: Group
    public let kind: Kind
    public let defaultValue: Double
    public let help: String

    public var isToggle: Bool { kind == .toggle }

    /// Defaults describe a healthy set on a clean signal: enabling the stage
    /// changes nothing until a knob is turned.
    public static let all: [GlitchParam] = [
        GlitchParam(
            id: "signal_strength", label: "Signal strength", group: .reception,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 1,
            help: "Antenna signal level. Lowering it brings snow first, then flickering and lost colour as the colour burst drowns, then broken sync as the sync pulses do — the order a real set fails in."),
        GlitchParam(
            id: "vertical_hold", label: "Vertical hold", group: .reception,
            kind: .slider(min: -1, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "The vertical oscillator's free-running speed. Near the centre the sync pulses pull it into lock; past the lock range the picture rolls, with the blanking bar crossing the screen."),
        GlitchParam(
            id: "horizontal_hold", label: "Horizontal hold", group: .reception,
            kind: .slider(min: -1, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "The horizontal oscillator's free-running speed. Off centre the picture slides sideways as the AFC strains to hold it; further and lock breaks — the picture tears into diagonal bands and the colour goes wild."),
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
            help: "A reflected copy of the signal arriving late (multipath). Negative values invert it, as reflections often did. Its colour shifts with the delay, because the delayed colour carrier arrives at a different phase."),
        GlitchParam(
            id: "ghost_delay", label: "Ghost delay", group: .reception,
            kind: .slider(min: 0.2, max: 12, percent: false, unit: "µs"), defaultValue: 2,
            help: "How late the reflection arrives. 1 µs is about 2% of the picture width — a reflection path roughly 300 m longer than the direct one."),
        GlitchParam(
            id: "hum", label: "Hum", group: .reception,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Mains hum leaking into the video: light and dark bars that drift slowly up the picture (60 Hz hum against the 59.94 Hz colour field rate), bending the picture where the sync separator is pulled off."),
        GlitchParam(
            id: "closed_captions", label: "Caption data", group: .reception,
            kind: .toggle, defaultValue: 1,
            help: "Line 21 carries closed-caption data — the row of dashes visible in the blanking bar when the picture rolls."),
        GlitchParam(
            id: "head_switch", label: "Head switching", group: .tape,
            kind: .slider(min: 0, max: 8, percent: false, unit: "µs"), defaultValue: 0,
            help: "Timing jump when the VCR changes heads, just before vertical sync. The bottom lines jump sideways and the TV's AFC chases the jump into the top of the next field — the bend called flagging."),
        GlitchParam(
            id: "timebase_jitter", label: "Time-base jitter", group: .tape,
            kind: .slider(min: 0, max: 3, percent: false, unit: "µs"), defaultValue: 0,
            help: "Tape stretch and transport flutter. The TV's AFC follows the slow wander; the fast jitter shows as ragged lines."),
        GlitchParam(
            id: "crinkle", label: "Tape crinkle", group: .tape,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Creased tape passing the heads: bands of signal loss and violent timing errors, enough to knock the TV out of lock for a moment."),
        GlitchParam(
            id: "head_clog", label: "Head clog", group: .tape,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Debris on the video heads, lifting them off the tape: whole fields drop out to noise and lose their sync, more often as the clog worsens."),
        GlitchParam(
            id: "search_speed", label: "Search", group: .tape,
            kind: .slider(min: 1, max: 9, percent: false, unit: "×"), defaultValue: 1,
            help: "Fast-forward picture search. The spinning heads cross from track to track, reading noise between them: one fewer noise bar than the speed, drifting as the tracking phase slides, with the picture jumping at each crossing."),
        GlitchParam(
            id: "dropouts", label: "Dropouts", group: .tape,
            kind: .slider(min: 0, max: 1, percent: true, unit: ""), defaultValue: 0,
            help: "Oxide missing from the tape: brief losses of signal along a line."),
        GlitchParam(
            id: "dropout_compensation", label: "Dropout compensation", group: .tape,
            kind: .toggle, defaultValue: 1,
            help: "The VCR's fix for dropouts: replace the lost stretch with the same stretch of the line before. Off, they show as white streaks."),
    ]

    public static let byID: [String: GlitchParam] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static var defaultValues: [String: Double] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.defaultValue) })
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

    /// Knobs that change the receiver's evolving state (anything touching
    /// sync, timing or signal level). The rest — ghost, brightness, caption
    /// data, dropouts — are applied when the field is drawn, so changing them
    /// never needs the history re-run.
    public static let timingIDs: Set<String> = [
        "signal_strength", "vertical_hold", "horizontal_hold", "afc_speed", "hum",
        "head_switch", "timebase_jitter", "crinkle", "head_clog", "search_speed",
    ]

    public var timing: [String: Double] { values.filter { Self.timingIDs.contains($0.key) } }
}
