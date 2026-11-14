import SwiftUI
import CrtCore

/// The glitch stage's TV: a simulated receiver between the NTSC stage (or
/// the VCR) and the CRT. Every control is a knob a real set had, or a
/// condition of the signal reaching it; the glitches are how the simulated
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
                    .help("Simulate the TV's sync circuits and the signal reaching it. Every knob starts at a healthy set on a clean signal — turn one to break it. Turn on Animate in the palette to see it move.")
            }
            if panelExpanded {
                Group {
                    HStack {
                        Text("A real TV, failing")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { state.resetGlitch() }
                            .buttonStyle(.borderless)
                    }
                    ForEach(GlitchParam.controls(in: .reception)) { param in
                        GlitchControl(param: param)
                    }
                }
                .opacity(state.glitchEnabled ? 1 : 0.4)
                .allowsHitTesting(state.glitchEnabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One glitch-stage knob (the Glitch and VCR panels share these).
struct GlitchControl: View {
    @Environment(AppState.self) private var state
    let param: GlitchParam

    private var value: Binding<Double> {
        Binding(get: { state.glitchSettings[param.id] },
                set: { state.setGlitchValue(param.id, $0) })
    }

    var body: some View {
        switch param.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { value.wrappedValue >= 0.5 },
                                 set: { value.wrappedValue = $0 ? 1 : 0 })) {
                Text(param.label).font(.callout).lineLimit(1)
            }
            .toggleStyle(.switch)
            .padding(.leading, 12)
            .help(param.help)

        case .seed:
            HStack {
                Text(param.label).font(.callout).lineLimit(1)
                Text("#\(Int(value.wrappedValue))").font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Another") { value.wrappedValue = value.wrappedValue.rounded() + 1 }
                    .buttonStyle(.borderless)
            }
            .padding(.leading, 12)
            .help(param.help)

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
