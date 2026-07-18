import SwiftUI
import CrtCore

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            // Preserve source aspect ratio: PreviewView gets a frame matching
            // the source's aspect, centred in the available space.
            ZStack {
                Color(white: 0.04)
                PreviewView()
                    .aspectRatio(state.sourceAspect, contentMode: .fit)
                    .padding(8)
            }
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
                NtscPanel()
                Divider()
                ShaderPanel()
                Divider()
                ViewPanel()
                Divider()
                ExportPanel()
            }
            .padding(16)
        }
    }
}
