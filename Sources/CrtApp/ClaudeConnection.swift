import Foundation

/// "Connect to Claude…": registers this app's MCP server (`NTSCRT mcp`)
/// with Claude Desktop (its JSON config) and Claude Code (its `claude mcp`
/// command), or removes it. Other servers in those configs are left alone.
enum ClaudeConnection {
    static let serverName = "ntscrt"

    /// This executable, as the command Claude runs.
    static var executable: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).path
    }

    /// Why the app can't be connected from where it is, if it can't: a
    /// path that won't last (the disk image, or the copy macOS runs a
    /// quarantined download from).
    static var locationProblem: String? {
        let p = executable
        if p.contains("/AppTranslocation/") {
            return "macOS is running NTSCRT from a temporary copy. Move NTSCRT to your Applications folder, open it from there, and connect again."
        }
        if p.hasPrefix("/Volumes/") {
            return "NTSCRT is running from the disk image. Drag it to your Applications folder, open it from there, and connect again."
        }
        return nil
    }

    enum Status: Equatable {
        case notInstalled
        case notConnected
        case connected
        /// Connected, but to an NTSCRT somewhere else.
        case connectedElsewhere(String)
        case unreadable(String)
    }

    // MARK: - Claude Desktop

    /// CRT_CLAUDE_HOME stands in for the home folder in the self-check
    /// (CRT_CONNECT_SELFTEST), so it never touches the real settings.
    static var home: URL {
        ProcessInfo.processInfo.environment["CRT_CLAUDE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static var desktopSupport: URL {
        home.appendingPathComponent("Library/Application Support/Claude")
    }
    static var desktopConfig: URL { desktopSupport.appendingPathComponent("claude_desktop_config.json") }

    static var desktopInstalled: Bool {
        FileManager.default.fileExists(atPath: desktopSupport.path)
            || (ProcessInfo.processInfo.environment["CRT_CLAUDE_HOME"] == nil
                && FileManager.default.fileExists(atPath: "/Applications/Claude.app"))
    }

    /// The config as a dictionary; empty if the file doesn't exist yet.
    static func readDesktopConfig() throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: desktopConfig.path) else { return [:] }
        if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectError("Claude Desktop's settings file isn't valid JSON, so NTSCRT left it alone: \(desktopConfig.path)")
        }
        return obj
    }

    static var desktopStatus: Status {
        guard desktopInstalled else { return .notInstalled }
        do {
            let config = try readDesktopConfig()
            guard let entry = (config["mcpServers"] as? [String: Any])?[serverName] as? [String: Any] else { return .notConnected }
            let command = entry["command"] as? String ?? ""
            return command == executable ? .connected : .connectedElsewhere(command)
        } catch {
            return .unreadable((error as? ConnectError)?.message ?? error.localizedDescription)
        }
    }

    static func connectDesktop() throws {
        if let problem = locationProblem { throw ConnectError(problem) }
        var config = try readDesktopConfig()
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": executable, "args": ["mcp"]]
        config["mcpServers"] = servers
        try writeDesktopConfig(config)
    }

    static func disconnectDesktop() throws {
        var config = try readDesktopConfig()
        guard var servers = config["mcpServers"] as? [String: Any], servers[serverName] != nil else { return }
        servers.removeValue(forKey: serverName)
        config["mcpServers"] = servers
        try writeDesktopConfig(config)
    }

    /// Back up what's there, then write the new config.
    private static func writeDesktopConfig(_ config: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: desktopSupport, withIntermediateDirectories: true)
        if fm.fileExists(atPath: desktopConfig.path) {
            let backup = desktopSupport.appendingPathComponent("claude_desktop_config.json.before-ntscrt")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: desktopConfig, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: config,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: desktopConfig, options: .atomic)
    }

    // MARK: - Claude Code

    /// The `claude` command, where its installers put it (an app launched
    /// from the Finder doesn't get the shell's PATH).
    static var claudeCLI: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var codeCommand: String {
        "claude mcp add --scope user \(serverName) -- \(shellQuoted(executable)) mcp"
    }

    static func shellQuoted(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) } ? s
            : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Claude Code's user-scope servers live in ~/.claude.json.
    static var codeStatus: Status {
        guard claudeCLI != nil else { return .notInstalled }
        let file = home.appendingPathComponent(".claude.json")
        guard let data = FileManager.default.contents(atPath: file.path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (obj["mcpServers"] as? [String: Any])?[serverName] as? [String: Any]
        else { return .notConnected }
        let command = entry["command"] as? String ?? ""
        return command == executable ? .connected : .connectedElsewhere(command)
    }

    static func connectCode() throws {
        if let problem = locationProblem { throw ConnectError(problem) }
        guard let cli = claudeCLI else { throw ConnectError("Claude Code's `claude` command wasn't found.") }
        _ = try? run(cli, ["mcp", "remove", "--scope", "user", serverName])
        try run(cli, ["mcp", "add", "--scope", "user", serverName, "--", executable, "mcp"])
    }

    static func disconnectCode() throws {
        guard let cli = claudeCLI else { return }
        try run(cli, ["mcp", "remove", "--scope", "user", serverName])
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        // The installers' own folders, for a `claude` that runs node.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw ConnectError("`claude mcp` failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    struct ConnectError: Error, LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}
