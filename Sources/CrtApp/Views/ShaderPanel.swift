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
                ParamControl(param: param)
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

// MARK: - Param classification

/// What kind of UI control fits this declared parameter best.
enum ParamControlKind {
    /// Boolean (min=0, max=1, step=1). Render a Toggle.
    case toggle
    /// Small fixed enumeration. Render a segmented Picker (≤4) or menu Picker.
    case picker(values: [Float], segmented: Bool)
    /// Integer-stepped value with a moderate range. Render a Stepper.
    case stepper(intStep: Int)
    /// Continuous floating-point. Render a Slider.
    case slider
}

func classifyParam(_ p: LRShaderParam) -> ParamControlKind {
    let lo = Double(p.minimum)
    let hi = Double(p.maximum)
    let step = Double(p.step)
    let range = hi - lo

    // Degenerate ranges fall back to slider (which we'll sanitise downstream).
    guard step > 0, range > 0 else { return .slider }

    // Floating-point step → continuous slider.
    let isIntStep = step == step.rounded() && lo == lo.rounded() && hi == hi.rounded()
    if !isIntStep {
        return .slider
    }

    let count = Int((range / step).rounded()) + 1
    if count == 2 && lo == 0 && hi == 1 {
        return .toggle
    }
    if count >= 2 && count <= 4 {
        return .picker(values: enumerate(lo: lo, step: step, count: count), segmented: true)
    }
    if count >= 5 && count <= 8 {
        return .picker(values: enumerate(lo: lo, step: step, count: count), segmented: false)
    }
    if count <= 32 {
        return .stepper(intStep: Int(step))
    }
    // Many discrete int values → just use a slider.
    return .slider
}

private func enumerate(lo: Double, step: Double, count: Int) -> [Float] {
    (0..<count).map { Float(lo + Double($0) * step) }
}

// MARK: - Param control

private struct ParamControl: View {
    @Environment(AppState.self) private var state
    let param: LRShaderParam

    private var binding: Binding<Float> {
        Binding(
            get: { state.paramValues[param.name] ?? param.initial },
            set: { state.paramValues[param.name] = $0 }
        )
    }

    private var label: String {
        param.desc.isEmpty ? param.name : param.desc
    }

    var body: some View {
        switch classifyParam(param) {
        case .toggle:                          toggleView
        case .picker(let values, let seg):     pickerView(values: values, segmented: seg)
        case .stepper(let intStep):            stepperView(intStep: intStep)
        case .slider:                          sliderView
        }
    }

    // MARK: widgets

    private var toggleView: some View {
        Toggle(isOn: Binding(
            get: { binding.wrappedValue >= 0.5 },
            set: { binding.wrappedValue = $0 ? 1 : 0 }
        )) {
            Text(label).font(.callout).lineLimit(1)
        }
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private func pickerView(values: [Float], segmented: Bool) -> some View {
        let selection = Binding<Float>(
            get: {
                // Snap to the nearest declared value.
                let v = binding.wrappedValue
                return values.min(by: { abs($0 - v) < abs($1 - v) }) ?? v
            },
            set: { binding.wrappedValue = $0 }
        )
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout).lineLimit(1)
            if segmented {
                Picker("", selection: selection) {
                    ForEach(values, id: \.self) { v in
                        Text(formatChoice(v)).tag(v)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            } else {
                Picker("", selection: selection) {
                    ForEach(values, id: \.self) { v in
                        Text(formatChoice(v)).tag(v)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private func stepperView(intStep: Int) -> some View {
        let intBinding = Binding<Int>(
            get: { Int(binding.wrappedValue.rounded()) },
            set: { binding.wrappedValue = Float($0) }
        )
        return HStack {
            Text(label).font(.callout).lineLimit(1)
            Spacer()
            Stepper(value: intBinding,
                    in: Int(param.minimum)...Int(param.maximum),
                    step: max(1, intStep)) {
                Text("\(intBinding.wrappedValue)")
                    .font(.system(.callout, design: .monospaced))
                    .frame(minWidth: 28, alignment: .trailing)
            }
        }
    }

    private var sliderView: some View {
        // Sanitise bounds for SwiftUI's Slider preconditions.
        let lo = Double(param.minimum)
        let hiRaw = Double(param.maximum)
        let hi = hiRaw > lo ? hiRaw : lo + 1.0
        let range = hi - lo
        let stepRaw = Double(param.step)
        let step = stepRaw > 0 && stepRaw <= range ? stepRaw : max(range / 100, 1e-4)

        let dBinding = Binding<Double>(
            get: { Double(binding.wrappedValue) },
            set: { binding.wrappedValue = Float($0) }
        )

        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.callout).lineLimit(1)
                Spacer()
                Text(String(format: "%.3g", dBinding.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: dBinding, in: lo...hi, step: step)
        }
    }

    private func formatChoice(_ v: Float) -> String {
        // Integer values render without ".0".
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.2f", v)
    }
}
