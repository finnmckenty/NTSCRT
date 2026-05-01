import SwiftUI
import CrtCore

struct DownscalePanel: View {
    @Environment(AppState.self) private var state

    private struct ResolutionPreset: Hashable {
        let label: String
        let width: Int
        let height: Int
    }

    private let presets: [ResolutionPreset] = [
        .init(label: "SNES (256 × 224)",     width: 256, height: 224),
        .init(label: "NES (256 × 240)",      width: 256, height: 240),
        .init(label: "VGA (320 × 240)",      width: 320, height: 240),
        .init(label: "Arcade (384 × 288)",   width: 384, height: 288),
        .init(label: "VGA² (640 × 480)",     width: 640, height: 480),
    ]

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Downscale before shader", isOn: $state.downscaleEnabled)
                .font(.headline)

            Group {
                Text("Target resolution").font(.subheadline).foregroundStyle(.secondary)
                Menu {
                    ForEach(presets, id: \.self) { p in
                        Button(p.label) {
                            state.downscaleWidth = p.width
                            state.downscaleHeight = p.height
                        }
                    }
                    Divider()
                    Text("(custom: edit fields below)")
                } label: {
                    Text(currentLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Stepper("W \(state.downscaleWidth)", value: $state.downscaleWidth, in: 16...4096, step: 16)
                    Stepper("H \(state.downscaleHeight)", value: $state.downscaleHeight, in: 16...4096, step: 8)
                }
                .font(.caption)

                Text("Sampling").font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $state.downscaleMethod) {
                    ForEach(DownscaleMethod.allCases, id: \.self) { m in
                        Text(m.rawValue.capitalized).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .disabled(!state.downscaleEnabled)
            .opacity(state.downscaleEnabled ? 1 : 0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentLabel: String {
        for p in presets where p.width == state.downscaleWidth && p.height == state.downscaleHeight {
            return p.label
        }
        return "Custom (\(state.downscaleWidth) × \(state.downscaleHeight))"
    }
}
