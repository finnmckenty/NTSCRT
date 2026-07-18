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
        return arr.compactMap(parse(node:))
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
