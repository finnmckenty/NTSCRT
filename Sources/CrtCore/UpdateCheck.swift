import Foundation

/// Reading GitHub's latest release and comparing it with this build — the
/// logic behind the app's update check (UpdateChecker.swift has the menu,
/// the timing and the alert). The Windows version is port/app/src/update.rs;
/// keep the two in step.
public enum UpdateCheck {

    public struct Release: Equatable, Sendable {
        /// As tagged, without the "v": "0.23.0".
        public let version: String
        /// The release's page, where the downloads are.
        public let page: URL
        /// Its notes, GitHub's Markdown tidied to plain text.
        public let notes: String
    }

    public enum Outcome: Equatable, Sendable {
        case newer(Release)
        case upToDate(latest: String)
        case failed(String)
    }

    public static let feed = URL(string: "https://api.github.com/repos/finnmckenty/NTSCRT/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/finnmckenty/NTSCRT/releases")!

    /// The release a version string belongs to: "v0.22.1", "0.22.1" and
    /// "0.22.1-3-gf1f92f1" are all [0, 22, 1]; "dev" is nil.
    public static func parseVersion(_ s: String) -> [Int]? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") { t.removeFirst() }
        let core = t.split(whereSeparator: { "-+ ".contains($0) }).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard let major = parts.first ?? nil else { return nil }
        let minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        let patch = parts.count > 2 ? (parts[2] ?? 0) : 0
        return [major, minor, patch]
    }

    public static func compare(current: String, latest: Release) -> Outcome {
        guard let l = parseVersion(latest.version) else {
            return .failed("the latest release's version (\(latest.version)) isn't one this can read")
        }
        // A build without a version: anything released is worth knowing about.
        guard let c = parseVersion(current) else { return .newer(latest) }
        return l.lexicographicallyPrecedes(c) || l == c ? .upToDate(latest: latest.version) : .newer(latest)
    }

    /// GitHub's answer (a release as JSON) as a Release.
    public static func release(from data: Data) throws -> Release {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw UpdateCheckError("no version in GitHub's answer")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        return Release(version: version, page: page, notes: plainNotes(json["body"] as? String ?? ""))
    }

    /// GitHub's Markdown as plain text: headings and emphasis marks dropped,
    /// list bullets kept as "•".
    public static func plainNotes(_ md: String) -> String {
        let lines: [Substring] = md.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: Character("\n"), omittingEmptySubsequences: false)
        return lines
            .map { line -> String in
                let indent = line.prefix(while: { $0 == " " }).count
                var t = Substring(line.dropFirst(indent))
                while t.hasPrefix("#") { t = t.dropFirst() }
                t = Substring(t.drop(while: { $0 == " " }))
                var bullet = ""
                if t.hasPrefix("- ") || t.hasPrefix("* ") {
                    bullet = "• "
                    t = t.dropFirst(2)
                }
                let body = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                return String(repeating: " ", count: indent) + bullet + body
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct UpdateCheckError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
