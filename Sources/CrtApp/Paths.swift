import Foundation

/// Locates external assets the app needs at runtime.
///
/// In dev (running .build/debug/crt-app from the repo root), the library and
/// presets live in Vendor/. Override either via the CRT_LIBRASHADER and
/// CRT_PRESETS environment variables. A future signed .app bundle would put
/// these in Frameworks/ and Resources/.
enum Paths {

    enum Error: Swift.Error, LocalizedError {
        case notFound(String)
        var errorDescription: String? {
            if case .notFound(let s) = self { return "not found: \(s)" }
            return nil
        }
    }

    static func librashaderDylib() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["CRT_LIBRASHADER"] {
            let url = URL(fileURLWithPath: env)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        for candidate in candidates(suffix: "Vendor/librashader/librashader.dylib") {
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw Error.notFound("librashader.dylib (set CRT_LIBRASHADER or place at Vendor/librashader/librashader.dylib)")
    }

    /// The ntscrs-capi dylib (VHS stage). Optional — the app runs without it.
    static func ntscrsDylib() -> URL? {
        if let env = ProcessInfo.processInfo.environment["CRT_NTSCRS"] {
            let url = URL(fileURLWithPath: env)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        for candidate in candidates(suffix: "Vendor/ntscrs-capi/ntscrs_capi.dylib") {
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func slangShadersRoot() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["CRT_PRESETS"] {
            let url = URL(fileURLWithPath: env)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        for candidate in candidates(suffix: "Vendor/slang-shaders") {
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw Error.notFound("slang-shaders (set CRT_PRESETS or init the Vendor/slang-shaders submodule)")
    }

    private static func candidates(suffix: String) -> [URL] {
        var bases: [URL] = []
        bases.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            bases.append(dir)
            dir = dir.deletingLastPathComponent()
        }
        return bases.map { $0.appendingPathComponent(suffix) }
    }
}
