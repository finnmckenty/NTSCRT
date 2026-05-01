import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SourcePanel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source").font(.headline)

            HStack {
                Button("Open Image…") { openImage() }
                if state.sourceURL != nil {
                    Button("Clear", role: .destructive) {
                        state.sourceURL = nil
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let url = state.sourceURL {
                Text(url.lastPathComponent)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let tex = state.sourceTexture {
                    Text("\(tex.width) × \(tex.height) px")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Drop a PNG, JPEG, or HEIC here, or click Open.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let err = state.sourceError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    DispatchQueue.main.async { state.sourceURL = url }
                }
            }
            return true
        }
    }

    private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.sourceURL = url
        }
    }
}
