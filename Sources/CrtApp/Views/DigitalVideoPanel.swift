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
                    .help("Record the picture with a digital camera and codec before it goes out as an analog signal. Ready-made formats — webcam, video call, MiniDV and more — are in the toolbar's Preset menu, and also set the Downscale resolution.")
            }
            if panelExpanded {
                Group {
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
        // Switched on from the Preset menu (or a look): show it.
        .onChange(of: state.digitalEnabled) { _, on in if on { panelExpanded = true } }
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
                // Only the controls the chosen codec has.
                ForEach(DigitalParam.all.filter { $0.group == group && $0.applies(to: state.digitalSettings.codec) }) { param in
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
                set: { v in
                    let step = param.step
                    state.setDigitalValue(param.id, step.map { (v / $0).rounded() * $0 } ?? v)
                })
    }

    var body: some View {
        let reason = idleReason
        let idle = reason != nil
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
                    PropertySlider(value: value, range: min...max, step: param.step, neutral: param.defaultValue)
                }
            }
        }
        .disabled(idle)
        .opacity(idle ? 0.45 : 1)
        .padding(.leading, 12)
        .help(reason ?? param.help)
    }

    /// Why the control does nothing right now: it works on another that's at 0.
    private var idleReason: String? {
        let s = state.digitalSettings
        switch param.id {
        case "datamosh" where s["keyframe_interval"] <= 0:
            return "Set a keyframe interval above 0 first — datamoshing throws keyframes away."
        case "low_light_noise" where s["sensor_noise"] <= 0:
            return "Turn up Sensor noise first — this sets how much it grows in the dark."
        case "sharpening_width" where s["sharpening"] <= 0:
            return "Turn up Sharpening first — this sets how wide its halos reach."
        default:
            return nil
        }
    }
}
