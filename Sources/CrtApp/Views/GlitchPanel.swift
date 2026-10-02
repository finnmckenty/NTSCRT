import SwiftUI
import CrtCore

/// The glitch stage: a simulated TV receiver and VCR transport between the
/// NTSC stage and the CRT. Every control is a knob a real set or deck had
/// (or a condition of the signal); the glitches are how the simulated
/// circuits respond, so they combine and interact the way real ones did.
struct GlitchPanel: View {
    @Environment(AppState.self) private var state
    @State private var panelExpanded = true

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Twirl(expanded: $panelExpanded)
                Text("Glitch").font(.headline)
                Spacer()
                Toggle("", isOn: $state.glitchEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Simulate the TV's sync circuits and reception, and the VCR's transport. Every knob starts at a healthy set on a clean signal — turn one to break it. Turn on Animate in the palette to see it move.")
            }
            if panelExpanded {
                Group {
                    HStack {
                        Text("A real TV and VCR, failing")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { state.resetGlitch() }
                            .buttonStyle(.borderless)
                    }
                    ForEach(GlitchParam.Group.allCases, id: \.self) { group in
                        GlitchGroup(group: group)
                    }
                }
                .opacity(state.glitchEnabled ? 1 : 0.4)
                .allowsHitTesting(state.glitchEnabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GlitchGroup: View {
    @Environment(AppState.self) private var state
    let group: GlitchParam.Group
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
                ForEach(GlitchParam.all.filter { $0.group == group }) { param in
                    GlitchControl(param: param)
                }
            }
        }
        .padding(.leading, 12)
    }
}

private struct GlitchControl: View {
    @Environment(AppState.self) private var state
    let param: GlitchParam

    private var value: Binding<Double> {
        Binding(get: { state.glitchSettings[param.id] },
                set: { state.setGlitchValue(param.id, $0) })
    }

    var body: some View {
        switch param.kind {
        case .toggle:
            // Dropout compensation only has something to do once there are
            // dropouts; greyed out until then, like the CRT panel's gates.
            let idle = param.id == "dropout_compensation" && state.glitchSettings["dropouts"] == 0
            Toggle(isOn: Binding(get: { value.wrappedValue >= 0.5 },
                                 set: { value.wrappedValue = $0 ? 1 : 0 })) {
                Text(param.label).font(.callout).lineLimit(1)
            }
            .toggleStyle(.switch)
            .disabled(idle)
            .opacity(idle ? 0.45 : 1)
            .padding(.leading, 12)
            .help(idle ? "Turn up Dropouts first — this decides how they're concealed." : param.help)

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
                // Every glitch knob's default is the healthy, effect-free
                // setting, so that's where a double-click goes.
                PropertySlider(value: value, range: min...max, neutral: param.defaultValue)
            }
            .padding(.leading, 12)
            .help(param.help)
        }
    }
}
