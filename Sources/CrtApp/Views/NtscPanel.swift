import SwiftUI
import CrtCore

/// VHS / analog-signal degradation stage (ntsc-rs), applied to the chain
/// input after the downscale and before the CRT shader. Controls are
/// generated from ntsc-rs's own settings schema, so they match the ntsc-rs
/// desktop app (and its preset JSON is compatible both ways).
struct NtscPanel: View {
    @Environment(AppState.self) private var state
    @State private var panelExpanded = true

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Twirl(expanded: $panelExpanded)
                Text("VHS (ntsc-rs)").font(.headline)
                Spacer()
                if state.ntscAvailable {
                    Toggle("", isOn: $state.ntscEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help("Emulate the analog signal path (composite artifacts, tape noise) before the CRT shader. Turn on Animate in the View panel to see noise, jitter, and tracking move.")
                }
            }

            if !state.ntscAvailable {
                Text("ntscrs_capi.dylib not found — build it with scripts/build-ntscrs.sh (see README).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if panelExpanded {
                if let err = state.ntscError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                settingsBody
                    .opacity(state.ntscEnabled ? 1 : 0.4)
                    .allowsHitTesting(state.ntscEnabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var settingsBody: some View {
        HStack {
            Text("Settings (\(state.ntscDescriptors.count) top-level)")
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Button("Reset") { state.resetNtsc() }
                .buttonStyle(.borderless)
        }
        // Lazy: the full VHS list is ~80 AppKit-backed controls; building
        // only the visible rows keeps expand latency to a single beat.
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(state.ntscDescriptors) { setting in
                NtscControl(setting: setting, depth: 0)
            }
        }
    }
}

private struct NtscControl: View {
    @Environment(AppState.self) private var state
    let setting: NtscSetting
    let depth: Int
    @State private var groupExpanded = true

    var body: some View {
        switch setting.kind {
        case .boolean:
            Toggle(isOn: boolBinding) {
                Text(setting.label).font(.callout).lineLimit(1)
            }
            .toggleStyle(.switch)
            .padding(.leading, indent)
            .help(setting.description ?? "")

        case .percentage(let logarithmic):
            slider(min: 0, max: 1, logarithmic: logarithmic, percent: true)

        case .float(let min, let max, let logarithmic):
            slider(min: min, max: max, logarithmic: logarithmic, percent: false)

        case .int(let min, let max):
            intControl(min: min, max: max)

        case .enumeration(let options):
            VStack(alignment: .leading, spacing: 2) {
                Text(setting.label).font(.callout).lineLimit(1)
                Picker("", selection: intBinding) {
                    ForEach(options, id: \.index) { o in
                        Text(o.label).tag(o.index)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .padding(.leading, indent)
            .help(setting.description ?? "")

        case .group(let children):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Twirl(expanded: $groupExpanded)
                    Toggle(isOn: boolBinding) {
                        Text(setting.label).font(.callout).bold().lineLimit(1)
                    }
                    .toggleStyle(.switch)
                    .help(setting.description ?? "")
                }
                if state.ntscBool(setting.name) && groupExpanded {
                    ForEach(children) { child in
                        NtscControl(setting: child, depth: depth + 1)
                    }
                }
            }
            .padding(.leading, indent)
        }
    }

    private var indent: CGFloat { CGFloat(depth) * 12 }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { state.ntscBool(setting.name) },
            set: { state.setNtscValue(setting.name, $0) }
        )
    }

    private var intBinding: Binding<Int> {
        Binding(
            get: { Int(state.ntscNumber(setting.name)) },
            set: { state.setNtscValue(setting.name, $0) }
        )
    }

    private func slider(min: Double, max: Double, logarithmic: Bool, percent: Bool) -> some View {
        // v1 renders logarithmic ranges linearly; ranges are still correct.
        let binding = Binding<Double>(
            get: { state.ntscNumber(setting.name) },
            set: { state.setNtscValue(setting.name, $0) }
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(setting.label).font(.callout).lineLimit(1)
                Spacer()
                if percent {
                    // Edited in percent units ("15.3" = 0.153).
                    NumericField(
                        value: Binding(
                            get: { binding.wrappedValue * 100 },
                            set: { binding.wrappedValue = $0 / 100 }
                        ),
                        range: (min * 100)...(max * 100),
                        width: 56
                    )
                    Text("%").font(.caption).foregroundStyle(.secondary)
                } else {
                    NumericField(value: binding, range: min...max)
                }
            }
            Slider(value: binding, in: min...max)
        }
        .padding(.leading, indent)
        .help(setting.description ?? "")
    }

    @ViewBuilder
    private func intControl(min: Int, max: Int) -> some View {
        // Huge ranges (random_seed spans all of Int32) get a text field.
        if max - min > 10_000 {
            HStack {
                Text(setting.label).font(.callout).lineLimit(1)
                Spacer()
                IntField(value: intBinding, range: min...max, width: 110)
            }
            .padding(.leading, indent)
            .help(setting.description ?? "")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(setting.label).font(.callout).lineLimit(1)
                    Spacer()
                    IntField(value: intBinding, range: min...max, width: 48)
                }
                Slider(
                    value: Binding(
                        get: { state.ntscNumber(setting.name) },
                        set: { state.setNtscValue(setting.name, Int($0.rounded())) }
                    ),
                    in: Double(min)...Double(max),
                    step: 1
                )
            }
            .padding(.leading, indent)
            .help(setting.description ?? "")
        }
    }
}
