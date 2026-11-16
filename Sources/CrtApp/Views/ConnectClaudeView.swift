import SwiftUI
import AppKit

/// The "Connect to Claude" window (NTSCRT menu).
struct ConnectClaudeView: View {
    @State private var desktop = ClaudeConnection.desktopStatus
    @State private var code = ClaudeConnection.codeStatus
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Claude").font(.headline)
            Text("Lets Claude use NTSCRT: describe a look in words, and Claude previews frames, adjusts the settings, renders the video and can save the look as a preset. Rendering happens on this Mac; Claude sees the preview frames it asks for.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem = ClaudeConnection.locationProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            row(title: "Claude Desktop", status: desktop,
                missing: "Claude Desktop isn't installed.",
                connect: { try ClaudeConnection.connectDesktop()
                           return "Connected. Quit Claude Desktop (⌘Q) and open it again to use NTSCRT." },
                disconnect: { try ClaudeConnection.disconnectDesktop()
                              return "Disconnected. Quit and reopen Claude Desktop for it to take effect." })

            row(title: "Claude Code", status: code,
                missing: "The `claude` command wasn't found. If you use Claude Code, run this in Terminal:",
                connect: { try ClaudeConnection.connectCode()
                           return "Connected. New Claude Code sessions can use NTSCRT." },
                disconnect: { try ClaudeConnection.disconnectCode()
                              return "Disconnected from Claude Code." })
            if code == .notInstalled {
                HStack {
                    Text(ClaudeConnection.codeCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ClaudeConnection.codeCommand, forType: .string)
                    }
                }
            }

            if let message {
                Text(message).font(.callout)
                    .foregroundStyle(messageIsError ? .red : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("To use it, give Claude a file's path (select it in Finder and press ⌥⌘C), then describe the look. Videos are saved in Movies › NTSCRT.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder
    private func row(title: String, status: ClaudeConnection.Status, missing: String,
                     connect: @escaping () throws -> String,
                     disconnect: @escaping () throws -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).bold()
                Spacer()
                switch status {
                case .connected:
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Disconnect") { act(disconnect) }
                case .notConnected, .connectedElsewhere:
                    Button("Connect") { act(connect) }
                        .disabled(ClaudeConnection.locationProblem != nil)
                case .notInstalled, .unreadable:
                    EmptyView()
                }
            }
            switch status {
            case .notInstalled:
                Text(missing).font(.caption).foregroundStyle(.secondary)
            case .connectedElsewhere(let other):
                Text("Connected to an NTSCRT at another location (\(other)). Connect to use this one.")
                    .font(.caption).foregroundStyle(.secondary)
            case .unreadable(let why):
                Text(why).font(.caption).foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }

    private func act(_ body: () throws -> String) {
        do {
            message = try body()
            messageIsError = false
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
        desktop = ClaudeConnection.desktopStatus
        code = ClaudeConnection.codeStatus
    }
}
