import Foundation

/// Screen Loop presets: the camera's knobs (and a still's length) as a
/// small JSON file, kept in a folder of their own — "Screen Loop" — so
/// they never mix with the look presets.
enum FeedbackPresets {
    static let folderName = "Screen Loop"
    static let kind = "ntscrt-video-feedback"

    /// Bundled with the app (read-only): presets/Screen Loop.
    static var bundledFolder: URL? {
        guard let root = Paths.lookPresetsRoot() else { return nil }
        let url = root.appendingPathComponent(folderName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The project's own folder when running from a checkout, so presets
    /// saved during development land where the build bundles them.
    static var projectFolder: URL? {
        Paths.projectPresetsFolder()?.appendingPathComponent(folderName)
    }

    /// Yours, for an installed app: Application Support/NTSCRT/Screen Loop.
    static var userFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NTSCRT").appendingPathComponent(folderName)
    }

    /// Where Save… starts: the project's folder in a checkout, else yours.
    static func saveFolder() -> URL {
        let folder = projectFolder ?? userFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Every preset found, by name — yours and the project's win over a
    /// bundled one of the same name.
    static func discover() -> [BuiltInPreset] {
        var byName: [String: BuiltInPreset] = [:]
        for folder in [bundledFolder, projectFolder, userFolder].compactMap({ $0 }) {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in items where url.pathExtension.lowercased() == "json" {
                let name = url.deletingPathExtension().lastPathComponent
                byName[name] = BuiltInPreset(name: name, url: url)
            }
        }
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
