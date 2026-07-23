import SwiftUI
import CrtAppBridge
import CrtCore

struct ShaderPanel: View {
    @Environment(AppState.self) private var state
    @State private var panelExpanded = true
    @State private var expandedSections: [String: Bool] = [:]

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Twirl(expanded: $panelExpanded)
                Text("Shader").font(.headline)
                Spacer()
                Toggle("", isOn: $state.shaderEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Enable/disable the CRT shader. Off shows the (optionally-downscaled) source.")
            }

            if panelExpanded {
                shaderConfig
                    .opacity(state.shaderEnabled ? 1 : 0.4)
                    .allowsHitTesting(state.shaderEnabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Contiguous run of parameters under one shader-declared section header
    /// (label pseudo-params like Hyllian's "SCANLINES SETTINGS:").
    private struct ParamSection: Identifiable {
        let id: String
        let title: String
        let params: [LRShaderParam]
    }

    /// Split the flat parameter list at section headers. Params before the
    /// first header stay flat; "//"-comment headers stay inline as captions.
    private func makeSections(_ all: [LRShaderParam]) -> (pre: [LRShaderParam], sections: [ParamSection]) {
        var pre: [LRShaderParam] = []
        var sections: [ParamSection] = []
        var current: (title: String, params: [LRShaderParam])? = nil

        func close() {
            if let c = current {
                sections.append(ParamSection(id: c.title, title: c.title, params: c.params))
            }
            current = nil
        }

        for p in all {
            let pres = presentation(for: p)
            if case .header = pres.kind {
                let title = pres.title.trimmingCharacters(in: .whitespaces)
                if title.isEmpty {
                    close()
                } else if title.hasPrefix("//") {
                    // Inline comment, not a section boundary.
                    if current != nil { current!.params.append(p) } else { pre.append(p) }
                } else {
                    close()
                    current = (title, [])
                }
            } else if current != nil {
                current!.params.append(p)
            } else {
                pre.append(p)
            }
        }
        close()
        return (pre, sections)
    }

    @ViewBuilder
    private var shaderConfig: some View {
        @Bindable var state = state
        let split = makeSections(state.paramDescriptors)
        VStack(alignment: .leading, spacing: 8) {
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

            ForEach(split.pre, id: \.name) { param in
                ParamControl(param: param)
            }
            ForEach(split.sections) { section in
                let expanded = Binding(
                    get: { expandedSections[section.id, default: true] },
                    set: { expandedSections[section.id] = $0 }
                )
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Twirl(expanded: expanded)
                        Text(section.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 4)
                    if expanded.wrappedValue {
                        ForEach(section.params, id: \.name) { param in
                            ParamControl(param: param)
                        }
                    }
                }
            }
        }
    }

    private func resetAll() {
        var values: [String: Float] = [:]
        for p in state.paramDescriptors {
            values[p.name] = AppState.appShaderDefaults[state.selectedPreset.id]?[p.name] ?? p.initial
        }
        state.setAllParams(values)
    }
}

// MARK: - Param classification

/// What kind of UI control fits this declared parameter best.
enum ParamControlKind {
    /// Non-interactive label row. Shaders declare params with min == max as
    /// section headers / comments (e.g. Hyllian's "COLOR SETTINGS:").
    case header
    /// Boolean (min=0, max=1, step=1) with no named choices. Render a Toggle.
    case toggle
    /// Small fixed enumeration. Render a segmented Picker (≤4) or menu Picker.
    /// `labels` names the choices when the description carried a matching
    /// "[A, B, C]" legend.
    case picker(values: [Float], labels: [String]?, segmented: Bool)
    /// Integer-stepped value with a moderate range. Render a Stepper.
    case stepper(intStep: Int)
    /// Continuous floating-point. Render a Slider.
    case slider
}

/// How a parameter should be presented: the control kind, the display title
/// (description with any consumed "[...]" legend stripped), and an optional
/// caption — a legend that names ranges rather than individual choices, e.g.
/// PHOSPHOR_LAYOUT's "[1-6 APERT, 7-10 DOT, 11-14 SLOT, 15-17 LOTTES]".
struct ParamPresentation {
    var kind: ParamControlKind
    var title: String
    var caption: String?
}

func presentation(for p: LRShaderParam) -> ParamPresentation {
    let lo = Double(p.minimum)
    let hi = Double(p.maximum)
    let step = Double(p.step)
    let range = hi - lo

    let desc = p.desc.trimmingCharacters(in: .whitespaces)
    let fallbackTitle = desc.isEmpty ? p.name : desc

    // Label pseudo-params: nothing to adjust, the description is the point.
    if range <= 0 {
        return ParamPresentation(kind: .header, title: desc, caption: nil)
    }

    guard step > 0 else {
        return ParamPresentation(kind: .slider, title: fallbackTitle, caption: nil)
    }

    let (strippedDesc, legend) = extractLegend(desc)
    let title = strippedDesc.isEmpty ? p.name : strippedDesc

    // Discrete iff the step divides the range into a whole number of
    // intervals — this also catches fractional-step enums like crt-royale's
    // subpixel offsets (-0.333…0.333, step 0.333 → three choices).
    let steps = range / step
    let isDiscrete = abs(steps - steps.rounded()) < 1e-3
    let count = Int(steps.rounded()) + 1
    let isIntStep = step == step.rounded() && lo == lo.rounded() && hi == hi.rounded()

    if isDiscrete && count >= 2 && count <= 8 {
        // A comma-separated legend naming exactly one choice per value
        // becomes the picker labels ("[SPHERE, CYLINDER]" etc.).
        var labels: [String]? = nil
        if let legend {
            let tokens = legend.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if tokens.count == count && tokens.allSatisfy({ !$0.isEmpty }) {
                labels = tokens
            }
        }

        // Plain unnamed on/off → toggle.
        if count == 2 && lo == 0 && hi == 1 && isIntStep && labels == nil {
            return ParamPresentation(kind: .toggle, title: title, caption: legend)
        }

        let values = enumerate(lo: lo, step: step, count: count)
        // Segments need room: only for few choices with short labels.
        let combinedLabelLength = labels?.reduce(0) { $0 + $1.count } ?? 0
        let segmented = count <= 4 && combinedLabelLength <= 24
        return ParamPresentation(
            kind: .picker(values: values, labels: labels, segmented: segmented),
            title: title,
            caption: labels == nil ? legend : nil
        )
    }

    // Not a small enum: any legend stays visible as a caption under the control.
    if isIntStep && isDiscrete && count <= 32 {
        return ParamPresentation(kind: .stepper(intStep: Int(step)), title: title, caption: legend)
    }
    return ParamPresentation(kind: .slider, title: title, caption: legend)
}

/// Splits the first "[...]" group out of a description.
/// "Curvature Shape [SPHERE, CYLINDER]" → ("Curvature Shape", "SPHERE, CYLINDER").
private func extractLegend(_ desc: String) -> (title: String, legend: String?) {
    guard let open = desc.firstIndex(of: "["),
          let close = desc[open...].firstIndex(of: "]"),
          open < close else {
        return (desc, nil)
    }
    let legend = String(desc[desc.index(after: open)..<close])
    var title = String(desc[..<open]) + String(desc[desc.index(after: close)...])
    title = title.replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: .whitespaces)
    guard !legend.trimmingCharacters(in: .whitespaces).isEmpty else {
        return (desc, nil)
    }
    return (title, legend)
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
            set: { state.setParam(param.name, $0) }
        )
    }

    var body: some View {
        let pres = presentation(for: param)
        let gate: ParamGate? = {
            if case .header = pres.kind { return nil }
            return ParamGates.gate(presetID: state.selectedPreset.id,
                                   paramName: param.name, desc: param.desc)
        }()
        let gateOpen: Bool = {
            guard let condition = gate?.condition else { return true }
            return ParamGates.isSatisfied(condition,
                                          paramValues: state.paramValues,
                                          inputHeight: state.chainInputHeight)
        }()

        VStack(alignment: .leading, spacing: 2) {
            Group {
                switch pres.kind {
                case .header:
                    headerView(title: pres.title)
                case .toggle:
                    toggleView(title: pres.title)
                case .picker(let values, let labels, let seg):
                    pickerView(title: pres.title, values: values, labels: labels, segmented: seg)
                case .stepper(let intStep):
                    stepperView(title: pres.title, intStep: intStep)
                case .slider:
                    sliderView(title: pres.title)
                }
            }
            .disabled(!gateOpen)
            .opacity(gateOpen ? 1 : 0.45)

            if let caption = pres.caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let gate, !gateOpen || gate.condition == nil {
                Text(gate.hint)
                    .font(.caption2)
                    .foregroundStyle(gateOpen ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: widgets

    @ViewBuilder
    private func headerView(title: String) -> some View {
        if !title.isEmpty {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleView(title: String) -> some View {
        Toggle(isOn: Binding(
            get: { binding.wrappedValue >= 0.5 },
            set: { binding.wrappedValue = $0 ? 1 : 0 }
        )) {
            Text(title).font(.callout).lineLimit(1)
        }
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private func pickerView(title: String, values: [Float], labels: [String]?, segmented: Bool) -> some View {
        let selection = Binding<Float>(
            get: {
                // Snap to the nearest declared value.
                let v = binding.wrappedValue
                return values.min(by: { abs($0 - v) < abs($1 - v) }) ?? v
            },
            set: { binding.wrappedValue = $0 }
        )
        let choices = Picker("", selection: selection) {
            ForEach(Array(values.enumerated()), id: \.element) { i, v in
                Text(labels?[i] ?? formatChoice(v)).tag(v)
            }
        }
        .labelsHidden()

        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).lineLimit(1)
            if segmented {
                choices.pickerStyle(.segmented)
            } else {
                choices.pickerStyle(.menu)
            }
        }
    }

    private func stepperView(title: String, intStep: Int) -> some View {
        let intBinding = Binding<Int>(
            get: { Int(binding.wrappedValue.rounded()) },
            set: { binding.wrappedValue = Float($0) }
        )
        return HStack {
            Text(title).font(.callout).lineLimit(1)
            Spacer()
            Stepper(value: intBinding,
                    in: Int(param.minimum)...Int(param.maximum),
                    step: max(1, intStep)) {
                IntField(value: intBinding,
                         range: Int(param.minimum)...Int(param.maximum),
                         width: 40)
            }
        }
    }

    private func sliderView(title: String) -> some View {
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
                Text(title).font(.callout).lineLimit(1)
                Spacer()
                NumericField(value: dBinding, range: lo...hi)
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
