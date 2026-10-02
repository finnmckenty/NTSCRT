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

    /// The two sampling looks the sidebar offers. The engine also has
    /// nearest+, bilinear, bicubic and lanczos — too close to these to earn
    /// the clutter, but kept so looks saved with them still render.
    private static let sampling: [(label: String, method: DownscaleMethod)] = [
        ("Chunky", .nearest),
        ("Smooth", .area),
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

                HStack {
                    Text("Sampling").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: samplingBinding) {
                        ForEach(Self.sampling, id: \.method) { s in
                            Text(s.label).tag(Optional(s.method))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Chunky takes one source pixel per block — hard pixel edges (on detailed video they can shimmer). Smooth averages the whole block — softer, steady.")
                }
                // The other kernels stay in the engine; a look saved with one
                // still renders with it, and says so here.
                if !Self.sampling.contains(where: { $0.method == state.downscaleMethod }) {
                    Text("Using \(state.downscaleMethod.displayName), from the loaded preset.")
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

    /// nil — no segment lit — while a preset's other kernel is in use.
    private var samplingBinding: Binding<DownscaleMethod?> {
        Binding(
            get: {
                Self.sampling.contains { $0.method == state.downscaleMethod } ? state.downscaleMethod : nil
            },
            set: { if let m = $0 { state.downscaleMethod = m } }
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
