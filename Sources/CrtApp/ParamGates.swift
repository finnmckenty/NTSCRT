import Foundation

/// Why a shader parameter can look "dead": most only take effect when another
/// parameter opens their code path, a few need particular input resolutions,
/// and a couple are compile-time disabled in the shader source itself (they
/// do nothing in RetroArch either). The UI uses these rules to gray out
/// inactive controls and say what would activate them.
///
/// Every rule here was verified empirically with crt-sweep: the param shows
/// ~zero pixel diff across its whole range with the gate closed, and a
/// substantial diff with the gate open.

enum GateCondition {
    /// Another parameter must be >= the threshold.
    case paramAtLeast(String, Float)
    /// Another parameter must be < the threshold.
    case paramBelow(String, Float)
    /// The chain input (downscaled size if enabled, else source) must be at
    /// least this many lines tall.
    case inputHeightAtLeast(Int)
    /// Compile-time disabled in this build of the shader source — behaves
    /// identically in RetroArch.
    case never
}

struct ParamGate {
    /// nil = informational only: the control stays enabled, the hint is shown.
    let condition: GateCondition?
    let hint: String
}

enum ParamGates {

    /// Returns the gate for a parameter, if any.
    static func gate(presetID: String, paramName: String, desc: String) -> ParamGate? {
        if let g = table[presetID]?[paramName] { return g }
        // Hyllian marks preset-overridden params with a leading "*":
        // "// Presets greater than 0 disable options with '*'."
        if presetID == "hyllian", desc.trimmingCharacters(in: .whitespaces).hasPrefix("*") {
            return ParamGate(condition: .paramBelow("PRESET_OPTION", 0.5),
                             hint: "Overridden unless Mask Preset is CUSTOM")
        }
        return nil
    }

    static func isSatisfied(_ condition: GateCondition,
                            paramValues: [String: Float],
                            inputHeight: Int?) -> Bool {
        switch condition {
        case .paramAtLeast(let name, let threshold):
            return (paramValues[name] ?? 0) >= threshold
        case .paramBelow(let name, let threshold):
            return (paramValues[name] ?? 0) < threshold
        case .inputHeightAtLeast(let lines):
            guard let h = inputHeight else { return false }
            return h >= lines
        case .never:
            return false
        }
    }

    // MARK: - rules

    private static let glowGates: [String: ParamGate] = [
        "warpX":        .init(condition: .paramAtLeast("CURVATURE", 0.5), hint: "Requires Curvature"),
        "warpY":        .init(condition: .paramAtLeast("CURVATURE", 0.5), hint: "Requires Curvature"),
        "cornersize":   .init(condition: .paramAtLeast("CURVATURE", 0.5), hint: "Requires Curvature"),
        "cornersmooth": .init(condition: .paramAtLeast("CURVATURE", 0.5), hint: "Requires Curvature"),
        "noise_amt":    .init(condition: .paramAtLeast("CURVATURE", 0.5), hint: "Requires Curvature"),
        "maskDark":     .init(condition: .paramAtLeast("shadowMask", 0.5), hint: "Requires Mask Effect > 0"),
        "maskLight":    .init(condition: .paramAtLeast("shadowMask", 0.5), hint: "Requires Mask Effect > 0"),
    ]

    private static let table: [String: [String: ParamGate]] = [
        // The two CRT Glow variants share one parameter set.
        "glow_gauss": glowGates,
        "glow_lanczos": glowGates,

        "hyllian": [
            "GLOW_WHITEPOINT": .init(condition: .paramAtLeast("GLOW_ENABLE", 0.5), hint: "Requires Enable Glow"),
            "GLOW_ROLLOFF":    .init(condition: .paramAtLeast("GLOW_ENABLE", 0.5), hint: "Requires Enable Glow"),
            "GLOW_RADIUS":     .init(condition: .paramAtLeast("GLOW_ENABLE", 0.5), hint: "Requires Enable Glow"),
            "GLOW_STRENGTH":   .init(condition: .paramAtLeast("GLOW_ENABLE", 0.5), hint: "Requires Enable Glow"),
            "h_shape":         .init(condition: .paramAtLeast("h_curvature", 0.5), hint: "Requires Curvature"),
            "h_radius":        .init(condition: .paramAtLeast("h_curvature", 0.5), hint: "Requires Curvature"),
            "h_cornersize":    .init(condition: .paramAtLeast("h_curvature", 0.5), hint: "Requires Curvature"),
            "h_cornersmooth":  .init(condition: .paramAtLeast("h_curvature", 0.5), hint: "Requires Curvature"),
            "DISPLAY_RES":     .init(condition: .paramAtLeast("PRESET_OPTION", 0.5), hint: "Only used by non-CUSTOM mask presets"),
            "MASK_STRENGTH":   .init(condition: .paramBelow("PRESET_OPTION", 0.5), hint: "Overridden unless Mask Preset is CUSTOM"),
            // Only mask layouts with asymmetric RGB triads respond to a
            // subpixel-order swap; magenta/green layouts are symmetric.
            "MONITOR_SUBPIXELS": .init(condition: nil, hint: "Only affects RGB-triad mask layouts"),
        ],

        "royale": [
            "geom_tilt_angle_x": .init(condition: .paramAtLeast("geom_mode_runtime", 0.5), hint: "Requires Geometry Mode ≠ flat"),
            "geom_tilt_angle_y": .init(condition: .paramAtLeast("geom_mode_runtime", 0.5), hint: "Requires Geometry Mode ≠ flat"),
            "geom_view_dist":    .init(condition: .paramAtLeast("geom_mode_runtime", 0.5), hint: "Requires Geometry Mode ≠ flat"),
            "geom_radius":       .init(condition: .paramAtLeast("geom_mode_runtime", 0.5), hint: "Requires Geometry Mode ≠ flat"),
            "aa_cubic_c":        .init(condition: .paramAtLeast("geom_mode_runtime", 0.5), hint: "Requires Geometry Mode ≠ flat"),
            "mask_num_triads_desired": .init(condition: .paramAtLeast("mask_specify_num_triads", 0.5), hint: "Requires Specify Number of Triads"),
            "interlace_detect_toggle": .init(condition: .inputHeightAtLeast(480), hint: "Needs a ≥480-line input"),
            "interlace_bff":     .init(condition: .inputHeightAtLeast(480), hint: "Needs a ≥480-line input"),
            "interlace_1080i":   .init(condition: .inputHeightAtLeast(1080), hint: "Needs a 1080-line input"),
            // Compile-time static in user-settings.h (RUNTIME_* undefined) —
            // these do nothing in RetroArch with this shader build either.
            "aa_subpixel_r_offset_x_runtime": .init(condition: .never, hint: "Static in this shader build"),
            "aa_subpixel_r_offset_y_runtime": .init(condition: .never, hint: "Static in this shader build"),
            "aa_gauss_sigma":    .init(condition: .never, hint: "Static in this shader build"),
            "beam_horiz_sigma":  .init(condition: .never, hint: "Static in this shader build"),
        ],

        "easymode": [
            "MASK_DOT_HEIGHT": .init(condition: .paramAtLeast("MASK_STAGGER", 1), hint: "Requires Mask Stagger > 0"),
        ],

        "aperture": [
            // The shader computes the half-line offset only when
            // floor(outputHeight / inputHeight) is even — at odd scale
            // factors the toggle is a byte-identical no-op (same in
            // RetroArch). Integer scale makes the factor explicit.
            "SCANLINE_OFFSET": .init(condition: nil, hint: "Only shifts at even output÷input scale factors"),
        ],

        "sim": [
            "animate_artifacts": .init(condition: nil, hint: "Visible with Animate on"),
        ],
    ]
}
