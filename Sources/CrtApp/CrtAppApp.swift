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
            appState = try AppState(context: context, presetsRoot: presetsRoot)
        } catch {
            bootstrapError = "\(error.localizedDescription)\n\nlibrashader dylib + slang-shaders submodule must be discoverable. See README."
        }
    }
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
