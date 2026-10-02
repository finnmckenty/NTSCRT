import Foundation
import CrtCore

/// Segment easing, carried per keyframe and applied to the segment leaving
/// that keyframe (CSS semantics: ease-in = slow start of the segment).
enum KeyEasing: String, CaseIterable {
    case linear = "Linear"
    case easeIn = "Ease in"
    case easeOut = "Ease out"
    case easeInOut = "Ease in-out"
    case hold = "Hold"

    /// Shape normalized segment progress 0…1.
    func apply(_ u: Double) -> Double {
        switch self {
        case .linear:    return u
        case .easeIn:    return u * u
        case .easeOut:   return 1 - (1 - u) * (1 - u)
        case .easeInOut: return u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
        case .hold:      return 0
        }
    }
}

/// A master keyframe: a whole-state snapshot of every animatable parameter.
/// Everything keys together — params left unchanged between two keyframes
/// interpolate between equal values, i.e. hold still automatically.
struct Keyframe: Identifiable {
    var id = UUID()
    /// Normalized position 0…1. Proportional timing: changing the video
    /// duration stretches the whole animation.
    var t: Double
    var easing: KeyEasing = .linear
    var shaderParams: [String: Float]
    var ntscValues: [String: Any]
    /// Glitch-stage knobs (GlitchParam ids). Empty in keyframes saved
    /// before the stage existed: they then leave the knobs alone.
    var glitchValues: [String: Double] = [:]
}

/// Value-captured interpolation engine, safe to hand to the exporter's
/// render thread (built once on the main thread; contents are read-only
/// value types after that — the [String: Any] leaves hold plist scalars).
struct TimelineEvaluator: @unchecked Sendable {

    /// How a ntsc-rs setting interpolates, derived from its descriptor.
    enum NtscInterp {
        case lerp        // float / percentage
        case lerpInt     // int — lerp then round
        case hold        // bool / enum / unknown ("version", …)
    }

    struct ShaderMeta {
        let minimum: Float
        let maximum: Float
        let step: Float
    }

    let keys: [Keyframe]                    // sorted by t, non-empty
    let shaderMeta: [String: ShaderMeta]
    let ntscInterp: [String: NtscInterp]

    init?(keys: [Keyframe],
          shaderMeta: [String: ShaderMeta],
          ntscInterp: [String: NtscInterp]) {
        guard !keys.isEmpty else { return nil }
        self.keys = keys.sorted { $0.t < $1.t }
        self.shaderMeta = shaderMeta
        self.ntscInterp = ntscInterp
    }

    /// Segment lookup: returns (a, b, eased-progress). Clamps outside the
    /// first/last keyframe.
    private func segment(at t: Double) -> (a: Keyframe, b: Keyframe, u: Double) {
        guard let first = keys.first, let last = keys.last else {
            fatalError("evaluator constructed empty")
        }
        if t <= first.t || keys.count == 1 { return (first, first, 0) }
        if t >= last.t { return (last, last, 0) }
        var a = first
        var b = last
        for k in keys {
            if k.t <= t { a = k } else { b = k; break }
        }
        let span = b.t - a.t
        let raw = span > 0 ? (t - a.t) / span : 0
        return (a, b, a.easing.apply(min(1, max(0, raw))))
    }

    func shaderParams(at t: Double) -> [String: Float] {
        let (a, b, u) = segment(at: t)
        if u == 0 { return a.shaderParams }
        var out: [String: Float] = [:]
        out.reserveCapacity(a.shaderParams.count)
        for (name, va) in a.shaderParams {
            let vb = b.shaderParams[name] ?? va
            var v = va + (vb - va) * Float(u)
            // Snap to the parameter's step grid: imperceptible on fine-step
            // sliders (≤ what the UI can set anyway) and it keeps discrete
            // params (toggles, pickers, steppers) on legal values instead of
            // meaningless in-betweens.
            if let m = shaderMeta[name] {
                if m.step > 0 {
                    v = m.minimum + ((v - m.minimum) / m.step).rounded() * m.step
                }
                v = min(m.maximum, max(m.minimum, v))
            }
            out[name] = v
        }
        return out
    }

    func ntscValues(at t: Double) -> [String: Any] {
        let (a, b, u) = segment(at: t)
        if u == 0 { return a.ntscValues }
        var out: [String: Any] = [:]
        out.reserveCapacity(a.ntscValues.count)
        for (name, rawA) in a.ntscValues {
            let interp = ntscInterp[name] ?? .hold
            guard interp != .hold,
                  let na = (rawA as? NSNumber), !isBool(na),
                  let nb = (b.ntscValues[name] as? NSNumber), !isBool(nb) else {
                out[name] = rawA
                continue
            }
            let v = na.doubleValue + (nb.doubleValue - na.doubleValue) * u
            out[name] = interp == .lerpInt ? Int(v.rounded()) as Any : v as Any
        }
        return out
    }

    /// Sliders interpolate; toggles hold until the next keyframe.
    func glitchValues(at t: Double) -> [String: Double] {
        let (a, b, u) = segment(at: t)
        if u == 0 { return a.glitchValues }
        var out: [String: Double] = [:]
        for (id, va) in a.glitchValues {
            let vb = b.glitchValues[id] ?? va
            out[id] = (GlitchParam.byID[id]?.isToggle ?? false) ? va : va + (vb - va) * u
        }
        return out
    }

    /// The glitch settings at `t`, starting from `base` for knobs the
    /// keyframes don't carry.
    func glitchSettings(at t: Double, base: [String: Double]) -> GlitchSettings {
        GlitchSettings(values: base.merging(glitchValues(at: t)) { _, new in new })
    }

    func ntscJSON(at t: Double) -> String? {
        let values = ntscValues(at: t)
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// NSNumber wrapping a Bool bridges as a number; interpolating it would
    /// produce 0.4-style garbage for toggles.
    private func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }
}
