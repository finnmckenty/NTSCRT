import SwiftUI
import AppKit
import CrtAppBridge
import CrtCore

@main
struct CrtAppApp: App {

    @State private var bootstrapError: String?
    @State private var appState: AppState?

    var body: some Scene {
        WindowGroup {
            Group {
                if let appState {
                    ContentView()
                        .environment(appState)
                } else if let bootstrapError {
                    BootstrapErrorView(message: bootstrapError)
                } else {
                    ProgressView("Starting…")
                        .frame(minWidth: 900, minHeight: 600)
                        .task { await bootstrap() }
                }
            }
        }
        .windowResizability(.contentSize)
    }

    private func bootstrap() async {
        do {
            let dylib = try Paths.librashaderDylib()
            try LRShaderChain.loadLibrary(dylib.path)
            let context = try MetalContext()
            let presetsRoot = try Paths.slangShadersRoot()
            if ProcessInfo.processInfo.environment["CRT_DUMP_CONTROLS"] != nil {
                dumpControls(presetsRoot: presetsRoot, context: context) // exits
            }
            let state = try AppState(context: context, presetsRoot: presetsRoot)
            // Dev/scripting conveniences: preload a source image or video,
            // and/or start on a specific preset (by id, e.g. "hyllian").
            if let src = ProcessInfo.processInfo.environment["CRT_SOURCE"] {
                state.sourceURL = URL(fileURLWithPath: src)
            }
            if let presetID = ProcessInfo.processInfo.environment["CRT_PRESET"],
               let preset = Presets.all.first(where: { $0.id == presetID }) {
                state.selectedPreset = preset
            }
            appState = state
        } catch {
            bootstrapError = "\(error.localizedDescription)\n\nlibrashader dylib + slang-shaders submodule must be discoverable. See README."
        }
    }
}

/// Diagnostic (CRT_DUMP_CONTROLS=1): print the UI control each shader
/// parameter classifies to, for every bundled preset, then exit. Lets the
/// param→control mapping be inspected without clicking through the app.
private func dumpControls(presetsRoot: URL, context: MetalContext) {
    for preset in Presets.all {
        let url = presetsRoot.appendingPathComponent(preset.relativePath)
        print("== \(preset.displayName) ==")
        guard let chain = try? LRShaderChain(presetPath: url.path,
                                             commandQueue: context.queue) else {
            print("  (chain failed to compile)")
            continue
        }
        // Match the panel: one row per unique name (passes re-declare params).
        var seen = Set<String>()
        for p in chain.parameters() where seen.insert(p.name).inserted {
            let pres = presentation(for: p)
            let kind: String
            switch pres.kind {
            case .header:
                kind = "header"
            case .toggle:
                kind = "toggle"
            case .picker(let values, let labels, let segmented):
                let style = segmented ? "segmented" : "menu"
                let names = labels.map { " {" + $0.joined(separator: "|") + "}" } ?? ""
                kind = "picker[\(values.count),\(style)]\(names)"
            case .stepper(let intStep):
                kind = "stepper(step \(intStep))"
            case .slider:
                kind = "slider"
            }
            let caption = pres.caption.map { "  ⌞\($0)" } ?? ""
            print("  \(kind.padding(toLength: 30, withPad: " ", startingAt: 0)) \(p.name)  \"\(pres.title)\"\(caption)")
        }
    }
    exit(0)
}

private struct BootstrapErrorView: View {
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CRT App could not start").font(.title2)
            Text(message).font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 200, alignment: .topLeading)
    }
}
