import Foundation
import AppKit
import SwiftUI

/// CRT_CONNECT_SELFTEST=<out.png> CRT_CLAUDE_HOME=<scratch home>: connect
/// and disconnect Claude Desktop in the scratch home (keeping another
/// server already there), print PASS/FAIL lines, snapshot the window.
@MainActor
enum ConnectSelfTest {
    static func run(snapshot: String) -> Never {
        guard ProcessInfo.processInfo.environment["CRT_CLAUDE_HOME"] != nil else {
            print("CONNECT FAIL: set CRT_CLAUDE_HOME to a scratch folder"); exit(1)
        }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("CONNECT \(ok ? "PASS" : "FAIL") \(name) \(detail)")
            if !ok { failures += 1 }
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: ClaudeConnection.desktopSupport, withIntermediateDirectories: true)
        let existing = #"{"mcpServers":{"other":{"command":"/bin/echo","args":["hi"]}},"globalShortcut":"Cmd+Space"}"#
        try? Data(existing.utf8).write(to: ClaudeConnection.desktopConfig)
        check("starts not connected", ClaudeConnection.desktopStatus == .notConnected, "\(ClaudeConnection.desktopStatus)")
        do { try ClaudeConnection.connectDesktop() } catch { check("connect", false, "\(error)") }
        check("connected", ClaudeConnection.desktopStatus == .connected, "\(ClaudeConnection.desktopStatus)")
        let after = (try? ClaudeConnection.readDesktopConfig()) ?? [:]
        let servers = after["mcpServers"] as? [String: Any] ?? [:]
        check("kept the other server", servers["other"] != nil)
        check("kept other settings", after["globalShortcut"] as? String == "Cmd+Space")
        check("backed up", fm.fileExists(atPath: ClaudeConnection.desktopSupport
            .appendingPathComponent("claude_desktop_config.json.before-ntscrt").path))

        renderSnapshot(to: snapshot)

        do { try ClaudeConnection.disconnectDesktop() } catch { check("disconnect", false, "\(error)") }
        check("disconnected", ClaudeConnection.desktopStatus == .notConnected)
        check("other server survives disconnect",
              ((try? ClaudeConnection.readDesktopConfig())?["mcpServers"] as? [String: Any])?["other"] != nil)
        try? Data("{ not json".utf8).write(to: ClaudeConnection.desktopConfig)
        var refused = false
        do { try ClaudeConnection.connectDesktop() } catch { refused = true }
        check("leaves a broken file alone", refused
              && String(decoding: fm.contents(atPath: ClaudeConnection.desktopConfig.path) ?? Data(), as: UTF8.self) == "{ not json")
        print(failures == 0 ? "CONNECT-ALL-PASS" : "CONNECT-FAILURES \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    static func renderSnapshot(to path: String) {
        let renderer = ImageRenderer(content: ConnectClaudeView().background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { print("CONNECT FAIL snapshot"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
