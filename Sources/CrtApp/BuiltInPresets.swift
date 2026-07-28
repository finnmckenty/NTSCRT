import Foundation

/// A look preset that ships with the app, listed in the Preset menu.
///
/// Discovered from the presets folder at launch rather than compiled in, so
/// dropping a .json file into `presets/` and rebuilding is all it takes to add
/// one — no code change. (`scripts/wrap-app.sh` and `make-release.sh` copy the
/// folder into the bundle.)
struct BuiltInPreset: Identifiable, Hashable {
    /// Shown in the menu: the filename without its extension ("Glitch 1").
    let name: String
    let url: URL

    var id: String { url.path }

    static func discover() -> [BuiltInPreset] {
        guard let root = Paths.lookPresetsRoot(),
              let items = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return [] }

        return items
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { BuiltInPreset(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            // Natural order, so "Glitch 2" sorts before "Glitch 10".
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
