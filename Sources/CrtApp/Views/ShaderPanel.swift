import SwiftUI
import CrtAppBridge
import CrtCore

struct ShaderPanel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            Text("Shader").font(.headline)

            Picker("Preset", selection: $state.selectedPreset) {
                ForEach(Presets.all) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .labelsHidden()

            if let err = state.chainError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Text("Parameters (\(state.paramDescriptors.count))")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { resetAll() }
                    .buttonStyle(.borderless)
                    .disabled(state.paramDescriptors.isEmpty)
            }

            ForEach(state.paramDescriptors, id: \.name) { param in
                ParamSlider(param: param)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resetAll() {
        var values: [String: Float] = [:]
        for p in state.paramDescriptors { values[p.name] = p.initial }
        state.paramValues = values
    }
}

private struct ParamSlider: View {
    @Environment(AppState.self) private var state
    let param: LRShaderParam

    var body: some View {
        let value = Binding<Double>(
            get: { Double(state.paramValues[param.name] ?? param.initial) },
            set: { state.paramValues[param.name] = Float($0) }
        )

        // Sanitise the bounds for SwiftUI's Slider, which preconditions on
        // `step > 0 && step <= (upperBound - lowerBound)` and
        // `lowerBound < upperBound`. Some preset params declare degenerate
        // ranges (min==max, or step larger than the range).
        let lo = Double(param.minimum)
        let hiRaw = Double(param.maximum)
        let hi = hiRaw > lo ? hiRaw : lo + 1.0      // ensure non-zero range
        let range = hi - lo
        let stepRaw = Double(param.step)
        let step = stepRaw > 0 && stepRaw <= range
            ? stepRaw
            : max(range / 100, 1e-4)                // safe fallback step

        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(param.desc.isEmpty ? param.name : param.desc)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.3g", value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: lo...hi, step: step)
        }
    }
}

