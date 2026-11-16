import Foundation
import AppKit

/// The executable's entry point: `NTSCRT render|describe|looks|mcp|help`
/// runs on the command line without a window; anything else opens the app.
@main
enum Launch {
    static func main() {
        if let out = ProcessInfo.processInfo.environment["CRT_CONNECT_SELFTEST"] {
            ConnectSelfTest.run(snapshot: out)
        }
        let args = Array(CommandLine.arguments.dropFirst())
        if let command = args.first, CLI.commands.contains(command) {
            CLI.start(command: command, arguments: Array(args.dropFirst()))
        }
        CrtAppApp.main()
    }
}

enum CLI {
    static let commands: Set<String> = ["render", "describe", "looks", "mcp", "help", "--help", "-h"]

    /// Where results go. Everything else the app prints (logs, the
    /// pipeline's diagnostics) is moved to stderr, so stdout carries only
    /// the result JSON (or, for `mcp`, the protocol).
    nonisolated(unsafe) static var resultOut: FileHandle = .standardOutput

    static func start(command: String, arguments: [String]) -> Never {
        let realStdout = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        resultOut = FileHandle(fileDescriptor: realStdout, closeOnDealloc: false)
        // No Dock icon or menu bar: this is a command-line tool run.
        NSApplication.shared.setActivationPolicy(.prohibited)

        Task { @MainActor in
            let code: Int32
            switch command {
            case "render": code = await RenderCommand.run(arguments)
            case "describe": code = await DescribeCommand.run(arguments)
            case "looks": code = await DescribeCommand.runLooks(arguments)
            case "mcp": code = await MCPServer.run(arguments)
            default:
                emitText(CLIHelp.text)
                code = 0
            }
            exit(code)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// One line on the result stream.
    static func emitText(_ text: String) {
        resultOut.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
    }

    static func emitJSON(_ object: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        resultOut.write(data + Data("\n".utf8))
    }

    static func prettyJSON(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A number for the JSON, rounded for reading (JSONSerialization
    /// prints a Double's full binary expansion).
    static func decimal(_ x: Double, places: Int = 2) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(places)f", x))
    }

    static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

struct CLIError: Error {
    let message: String
    /// 2 for a mistake in the command, 1 for a failed render.
    var code: Int32 = 2
}
