import SwiftUI
import CrtCore

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            PreviewView()
                .frame(minWidth: 480, minHeight: 360)
        }
        .frame(minWidth: 1000, minHeight: 640)
    }
}

private struct Sidebar: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SourcePanel()
                Divider()
                DownscalePanel()
                Divider()
                ShaderPanel()
                Divider()
                ExportPanel()
            }
            .padding(16)
        }
    }
}
