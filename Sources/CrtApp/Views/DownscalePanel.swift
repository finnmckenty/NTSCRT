import SwiftUI
import CrtCore

struct DownscalePanel: View {
    @Environment(AppState.self) private var state

    /// Console presets pick a horizontal resolution; the vertical always
    /// follows the source's aspect ratio, so any input shape works.
    private static let presets: [(label: String, width: Int)] = [
        ("SNES (256px)",   256),
        ("NES (256px)",    256),
        ("VGA (320px)",    320),
        ("Arcade (384px)", 384),
        ("VGA² (640px)",   640),
    ]

    @State private var expanded = true

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Twirl(expanded: $expanded)
                Toggle("Downscale before shader", isOn: $state.downscaleEnabled)
                    .font(.headline)
            }

            if expanded {
            Group {
                Text("Horizontal resolution").font(.subheadline).foregroundStyle(.secondary)
                Menu {
                    ForEach(Self.presets, id: \.label) { p in
                        Button(p.label) {
                            state.downscaleWidth = p.width
                            state.downscalePreset = p.label
                        }
                    }
                    Divider()
                    Button("Custom") {
                        state.downscalePreset = "Custom"
                    }
                } label: {
                    Text(currentLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Stepper(value: widthBinding, in: 16...4096, step: 16) {
                        HStack(spacing: 4) {
                            Text("W").font(.caption)
                            IntField(value: widthBinding, range: 16...4096, width: 52)
                        }
                    }
                    Spacer()
                    Text("→ \(state.downscaleWidth) × \(state.downscaleHeight)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help("Height follows the source's aspect ratio.")
                }

                Text("Sampling").font(.subheadline).foregroundStyle(.secondary)
                // Menu, not segmented: six segments exceed the sidebar's
                // width and clip the whole content column.
                Picker("", selection: $state.downscaleMethod) {
                    ForEach(DownscaleMethod.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                if state.downscaleMethod == .nearest {
                    Text("Tip: on video, Nearest shimmers in detailed areas — Nearest+ keeps the punch without the flicker.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!state.downscaleEnabled)
            .opacity(state.downscaleEnabled ? 1 : 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Editing the width by hand demotes the selection to Custom.
    private var widthBinding: Binding<Int> {
        Binding(
            get: { state.downscaleWidth },
            set: {
                state.downscaleWidth = $0
                if let p = Self.presets.first(where: { $0.label == state.downscalePreset }),
                   p.width != $0 {
                    state.downscalePreset = "Custom"
                }
            }
        )
    }

    private var currentLabel: String {
        if let p = Self.presets.first(where: { $0.label == state.downscalePreset }),
           p.width == state.downscaleWidth {
            return p.label
        }
        return "Custom (\(state.downscaleWidth)px)"
    }
}
