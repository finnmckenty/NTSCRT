import Foundation

/// Parsed form of the ntscrs-capi settings descriptor JSON — the schema the
/// VHS panel builds its controls from. Values themselves live in a flat
/// `[String: Any]` dictionary matching ntsc-rs's preset JSON (plus the
/// required `"version"` key).
struct NtscSetting: Identifiable {
    enum Kind {
        case boolean
        case percentage(logarithmic: Bool)
        case int(min: Int, max: Int)
        case float(min: Double, max: Double, logarithmic: Bool)
        case enumeration(options: [(label: String, index: Int)])
        case group(children: [NtscSetting])
        /// Collapsible heading with no on/off of its own — a grouping we add
        /// for readability, not something ntsc-rs has a setting for.
        case section(children: [NtscSetting])
    }

    let name: String        // stable JSON key
    let label: String
    let description: String?
    let kind: Kind

    var id: String { name }

    static func parse(descriptorsJSON: String) -> [NtscSetting] {
        guard let data = descriptorsJSON.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return houseLayout(arr.compactMap(parse(node:)))
    }

    /// Relabel and regroup a few of ntsc-rs's settings for legibility.
    ///
    /// Presentation only — the `name` keys, ranges and values are untouched,
    /// so preset JSON still round-trips with the ntsc-rs desktop app.
    static func houseLayout(_ settings: [NtscSetting]) -> [NtscSetting] {
        // "Scale" multiplies the whole signal stage, so it reads to a user as
        // the master intensity even though ntsc-rs frames it as a scale.
        let relabels: [String: String] = [
            "scale_settings": "Intensity",
            "bandwidth_scale": "Horizontal intensity",
            "vertical_scale": "Vertical intensity",
        ]
        // ntsc-rs allows these up to 8, but past ~3 the effect is mush — the
        // useful values all live low, so the slider spends its travel there.
        // The floor stays 0.125: the library silently clamps anything lower
        // up to it (verified), so a slider reaching 0 would show values the
        // effect isn't actually using. Preset JSON is unaffected — values
        // above 3 still load; the slider just pins until touched.
        let rangeOverrides: [String: (min: Double, max: Double)] = [
            "bandwidth_scale": (0.125, 3.0),
            "vertical_scale": (0.125, 3.0),
        ]
        func relabel(_ s: NtscSetting) -> NtscSetting {
            var kind = s.kind
            if case .group(let kids) = s.kind {
                kind = .group(children: kids.map(relabel))
            }
            if case .float(_, _, let log) = s.kind, let r = rangeOverrides[s.name] {
                kind = .float(min: r.min, max: r.max, logarithmic: log)
            }
            return NtscSetting(name: s.name,
                               label: relabels[s.name] ?? s.label,
                               description: s.description,
                               kind: kind)
        }
        var out = settings.map(relabel)

        // Four related chroma controls sit loose at the top level; collect
        // them under one heading.
        let chroma = ["chroma_phase_error", "chroma_phase_noise_intensity",
                      "chroma_delay_horizontal", "chroma_delay_vertical"]
        let members = chroma.compactMap { name in out.first { $0.name == name } }
        if members.count == chroma.count,
           let anchor = out.firstIndex(where: { $0.name == chroma[0] }) {
            out.removeAll { chroma.contains($0.name) }
            out.insert(NtscSetting(name: "chroma_distortion",
                                   label: "Chroma distortion",
                                   description: "Phase and delay errors in the colour subcarrier.",
                                   kind: .section(children: members)),
                       at: min(anchor, out.count))
        }

        // Intensity leads: it's the control most likely to be reached for.
        // Note: collapsing a group near the TOP costs more than one near the
        // bottom (every row below it has to be re-laid out) — measured 40 ms
        // here vs 9 ms mid-list. CRT_NO_HOUSE_ORDER=1 restores ntsc-rs's
        // order for that A/B.
        if ProcessInfo.processInfo.environment["CRT_NO_HOUSE_ORDER"] != "1",
           let i = out.firstIndex(where: { $0.name == "scale_settings" }) {
            out.insert(out.remove(at: i), at: 0)
        }
        return out
    }

    private static func parse(node: [String: Any]) -> NtscSetting? {
        guard let name = node["name"] as? String,
              let label = node["label"] as? String,
              let kindStr = node["kind"] as? String else { return nil }
        let desc = node["description"] as? String

        let kind: Kind
        switch kindStr {
        case "boolean":
            kind = .boolean
        case "percentage":
            kind = .percentage(logarithmic: node["logarithmic"] as? Bool ?? false)
        case "int":
            kind = .int(min: node["min"] as? Int ?? 0, max: node["max"] as? Int ?? 1)
        case "float":
            kind = .float(min: node["min"] as? Double ?? 0,
                          max: node["max"] as? Double ?? 1,
                          logarithmic: node["logarithmic"] as? Bool ?? false)
        case "enum":
            let opts = (node["options"] as? [[String: Any]] ?? []).compactMap {
                o -> (String, Int)? in
                guard let l = o["label"] as? String, let i = o["index"] as? Int else { return nil }
                return (l, i)
            }
            kind = .enumeration(options: opts)
        case "group":
            let children = (node["children"] as? [[String: Any]] ?? []).compactMap(parse(node:))
            kind = .group(children: children)
        default:
            return nil
        }
        return NtscSetting(name: name, label: label, description: desc, kind: kind)
    }
}
