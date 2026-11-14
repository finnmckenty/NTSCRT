import SwiftUI
import CrtCore

/// The VCR: the picture recorded onto a simulated VHS tape and played back
/// by a simulated deck. Two pickers set the tape's and the deck's condition
/// — the way you'd pick a cassette off the shelf and a deck to play it in —
/// and the knobs under each adjust it. Everything it does to the picture
/// comes from the recording physics (FM on slanted tracks, two heads,
/// spacing losses), see CrtCore/VcrStage.swift.
struct VcrPanel: View {
    @Environment(AppState.self) private var state
    @State private var panelExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Twirl(expanded: $panelExpanded)
                Text("VCR").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(get: { state.vcrEnabled }, set: { state.vcrEnabled = $0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(GlitchParam.byID[GlitchParam.vcrID]?.help ?? "")
            }
            if panelExpanded {
                Group {
                    HStack {
                        Text("A VHS tape in a real deck")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { state.resetVcr() }
                            .buttonStyle(.borderless)
                            .help("A brand-new tape in a deck with clean heads")
                    }
                    VcrSection(title: "Tape", group: .tape,
                               conditions: VcrCondition.tapes, keys: VcrCondition.tapeKeys)
                    VcrSection(title: "Deck", group: .deck,
                               conditions: VcrCondition.decks, keys: VcrCondition.deckKeys)
                }
                .opacity(state.vcrEnabled ? 1 : 0.4)
                .allowsHitTesting(state.vcrEnabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VcrSection: View {
    @Environment(AppState.self) private var state
    let title: String
    let group: GlitchParam.Group
    let conditions: [VcrCondition]
    let keys: [String]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Twirl(expanded: $expanded)
                Text(title).font(.callout).bold().lineLimit(1)
                Spacer(minLength: 8)
                Menu {
                    ForEach(conditions) { c in
                        Button(c.name) { state.applyVcrCondition(c, keys: keys) }
                            .help(c.help)
                    }
                } label: {
                    Text(current?.name ?? "Custom").lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Start from a typical \(title.lowercased()) condition, then adjust it below")
            }
            if expanded {
                ForEach(GlitchParam.controls(in: group)) { param in
                    GlitchControl(param: param)
                }
            }
        }
        .padding(.leading, 12)
    }

    private var current: VcrCondition? {
        VcrCondition.matching(conditions, keys: keys, in: state.glitchSettings.values)
    }
}
