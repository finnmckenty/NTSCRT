import Foundation

/// One of the six target shaders bundled with the app.
public struct PresetEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    /// Path relative to the slang-shaders root (e.g. "crt/crt-aperture.slangp").
    public let relativePath: String

    public init(id: String, displayName: String, relativePath: String) {
        self.id = id
        self.displayName = displayName
        self.relativePath = relativePath
    }
}

public enum Presets {
    public static let all: [PresetEntry] = [
        .init(id: "aperture",       displayName: "CRT Aperture",         relativePath: "crt/crt-aperture.slangp"),
        .init(id: "easymode",       displayName: "CRT Easymode",         relativePath: "crt/crt-easymode.slangp"),
        .init(id: "glow_gauss",     displayName: "CRT Glow (Gaussian)",  relativePath: "crt/crtglow_gauss.slangp"),
        .init(id: "glow_lanczos",   displayName: "CRT Glow (Lanczos)",   relativePath: "crt/crtglow_lanczos.slangp"),
        .init(id: "hyllian",        displayName: "CRT Hyllian",          relativePath: "crt/crt-hyllian.slangp"),
        .init(id: "royale",         displayName: "CRT Royale",           relativePath: "crt/crt-royale.slangp"),
        .init(id: "sim",            displayName: "CRT Sim",              relativePath: "crt/crtsim.slangp"),
    ]
}
