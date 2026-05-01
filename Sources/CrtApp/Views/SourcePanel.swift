import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SourcePanel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source").font(.headline)

            @Bindable var state = state
            HStack {
                Button("Open…") { openMedia() }
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
                if let vs = state.videoSource {
                    let total = vs.totalFrames
                    let idx = Binding<Double>(
                        get: { Double(state.currentFrameIndex) },
                        set: { state.currentFrameIndex = Int($0.rounded()) }
                    )
                    Slider(value: idx, in: 0...Double(max(1, total - 1)), step: 1)
                    Text("frame \(state.currentFrameIndex + 1) / \(total)  ·  \(String(format: "%.2fs", Double(state.currentFrameIndex) / Double(vs.frameRate)))  ·  \(String(format: "%.0f", vs.frameRate)) fps")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Drop an image (PNG/JPEG/HEIC) or video (MP4/MOV) here, or click Open.")
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

    private func openMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .mpeg4Movie, .quickTimeMovie, .png, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.sourceURL = url
        }
    }
}
