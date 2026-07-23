import SwiftUI
import UniformTypeIdentifiers

/// Save/load the whole visual configuration (downscale + VHS + shader +
/// view options) as a JSON preset file.
struct LookPanel: View {
    @Environment(AppState.self) private var state
    @State private var status: String = ""
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Twirl(expanded: $expanded)
                Text("Preset").font(.headline)
            }
            if expanded {
                HStack {
                    Button("Save…") { save() }
                    Button("Load…") { load() }
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "dd-MM-yy HH.mm.ss"
        return f.string(from: Date())
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ntscrt preset \(timestamp).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.saveLook(to: url)
            status = "Saved \(url.lastPathComponent)"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func load() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.loadLook(from: url)
            status = "Loaded \(url.lastPathComponent)"
        } catch {
            status = "Load failed: \(error.localizedDescription)"
        }
    }
}
