import SwiftUI
import CrtCore

/// The Digital video stage: a camera and a real block codec ahead of the
/// NTSC stage — footage recorded digitally, then played out to analog. A
/// format sets every control and the resolution (as the Downscale).
struct DigitalVideoPanel: View {
    @Environment(AppState.self) private var state
    /// Closed while the stage is off, to save room; opens when it's turned on.
    @State private var panelExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Twirl(expanded: $panelExpanded)
                Text("Digital video").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(get: { state.digitalEnabled },
                                         set: { on in
                                             state.setDigitalEnabled(on)
                                             if on { panelExpanded = true }
                                         }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Record the picture with a digital camera and codec before it goes out as an analog signal: webcam, video call, MiniDV and more. Choosing a format also sets the Downscale resolution.")
            }
            if panelExpanded {
                Group {
                    FormatRow()
                    ForEach(DigitalParam.Group.allCases, id: \.self) { group in
                        DigitalGroup(group: group)
                    }
                }
                .opacity(state.digitalEnabled ? 1 : 0.4)
                .allowsHitTesting(state.digitalEnabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { panelExpanded = state.digitalEnabled }
    }
}

private struct FormatRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Format").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(DigitalFormat.all) { f in
                        Button(f.name) { state.applyDigitalFormat(f) }
                    }
                } label: {
                    Text(state.digitalFormat?.name ?? "Custom")
                }
                .fixedSize()
                .help("Set every control below, and the Downscale resolution, to a format's.")
            }
            Text(caption)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The format's description, or what the custom settings amount to.
    private var caption: String {
        if let f = state.digitalFormat { return f.blurb }
        let s = state.digitalSettings
        var size = state.downscaleEnabled ? "\(state.downscaleWidth) × \(state.downscaleHeight)" : "full size"
        if let lines = state.downscaleFieldLines { size += ", one field of \(lines) lines" }
        let keys = s["keyframe_interval"] <= 0 ? "every frame on its own"
            : String(format: "a keyframe every %g s", s["keyframe_interval"])
        return "\(size) (the Downscale), \(Int(s["frame_rate"].rounded())) fps, \(keys)."
    }
}

private struct DigitalGroup: View {
    @Environment(AppState.self) private var state
    let group: DigitalParam.Group
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Twirl(expanded: $expanded)
                Text(group.rawValue).font(.callout).bold().lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { expanded.toggle() }
            }
            if expanded {
                ForEach(DigitalParam.all.filter { $0.group == group }) { param in
                    DigitalControl(param: param)
                }
            }
        }
        .padding(.leading, 12)
    }
}

private struct DigitalControl: View {
    @Environment(AppState.self) private var state
    let param: DigitalParam

    private var value: Binding<Double> {
        Binding(get: { state.digitalSettings[param.id] },
                set: { state.setDigitalValue(param.id, $0) })
    }

    var body: some View {
        // Datamosh throws keyframes away, so it needs some to throw.
        let idle = param.id == "datamosh" && state.digitalSettings["keyframe_interval"] <= 0
        Group {
            switch param.kind {
            case .choice(let names):
                HStack {
                    Text(param.label).font(.callout).lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(get: { Int(value.wrappedValue.rounded()) },
                                                  set: { value.wrappedValue = Double($0) })) {
                        ForEach(names.indices, id: \.self) { i in Text(names[i]).tag(i) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

            case .slider(let min, let max, let percent, let unit):
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(param.label).font(.callout).lineLimit(1)
                        Spacer()
                        if percent {
                            NumericField(value: Binding(get: { value.wrappedValue * 100 },
                                                        set: { value.wrappedValue = $0 / 100 }),
                                         range: (min * 100)...(max * 100), width: 56)
                            Text("%").font(.caption).foregroundStyle(.secondary)
                        } else {
                            NumericField(value: value, range: min...max, width: 56)
                            Text(unit).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    // Double-click returns to the Webcam format's value.
                    PropertySlider(value: value, range: min...max, neutral: param.defaultValue)
                }
            }
        }
        .disabled(idle)
        .opacity(idle ? 0.45 : 1)
        .padding(.leading, 12)
        .help(idle ? "Set a keyframe interval above 0 first — datamoshing throws keyframes away." : param.help)
    }
}
