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
                    // How the picture reaches the set: directly, or through
                    // the antenna socket in some state of repair. A starting
                    // point for the knobs below, as the VCR's Tape and Deck.
                    HStack(spacing: 4) {
                        Text("Connection").font(.callout).bold().lineLimit(1)
                        Spacer(minLength: 8)
                        Menu {
                            ForEach(VcrCondition.connections) { c in
                                Button(c.name) { state.applyVcrCondition(c, keys: VcrCondition.connectionKeys) }
                                    .help(c.help)
                            }
                        } label: {
                            Text(connection?.name ?? "Custom").lineLimit(1)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("How the picture reaches the TV: directly, or through its antenna socket (RF) on a good day or a bad one. Sets RF input and its five knobs, Signal strength, Ghost and Hum; adjust them below.")
                    }
                    .padding(.leading, 12)
                    let params = GlitchParam.controls(in: .reception)
                    ForEach(Array(params.enumerated()), id: \.element.id) { i, param in
                        if let section = param.section, i == 0 || params[i - 1].section != section {
                            Text(section)
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.leading, 12).padding(.top, 4)
                        }
                        // The tuner's knobs act only with the picture
                        // coming in through it.
                        let idle = param.id.hasPrefix("rf_") && !state.glitchSettings.flag("rf")
                        GlitchControl(param: param)
                            .opacity(idle ? 0.4 : 1)
                    }
                }
                .opacity(state.glitchEnabled ? 1 : 0.4)
                .allowsHitTesting(state.glitchEnabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connection: VcrCondition? {
        VcrCondition.matching(VcrCondition.connections, keys: VcrCondition.connectionKeys,
                              in: state.glitchSettings.values)
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

        case .choice(let names):
            HStack {
                Text(param.label).font(.callout).lineLimit(1)
                Spacer(minLength: 8)
                let picker = Picker("", selection: Binding(get: { Int(value.wrappedValue.rounded()) },
                                                           set: { value.wrappedValue = Double($0) })) {
                    ForEach(names.indices, id: \.self) { i in Text(names[i]).tag(i) }
                }
                .labelsHidden()
                .fixedSize()
                if names.count <= 3 { picker.pickerStyle(.segmented) } else { picker.pickerStyle(.menu) }
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
