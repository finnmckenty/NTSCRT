import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import CrtCore

/// Create Howlaround: a camcorder pointed at the TV that shows its own
/// picture, with your look on every pass. The knobs set up the camera; a
/// short, small draft re-renders as you turn them (the same render as the
/// final one, so it shows the same tunnel), and Render writes the full file.
struct HowlaroundPanel: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    /// Taller only for the off-screen snapshot, so every knob shows.
    var height: CGFloat = 700

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                preview
                Divider()
                knobs.frame(width: 330)
            }
            Divider()
            footer
        }
        .frame(width: 1040, height: height)
        .onAppear {
            // The renders drive the shared Metal queue (and librashader,
            // which isn't thread-safe), so the live preview pauses meanwhile.
            state.stopPlayback()
            state.stopTimelinePreview()
            state.exportInProgress = true
            state.howlPanelOpen = true
            // Your look may have changed since the last draft.
            state.scheduleHowlaroundDraft(delay: .zero)
        }
        .onChange(of: state.sourceTexture != nil || state.videoSource != nil) { _, hasSource in
            if hasSource { state.scheduleHowlaroundDraft(delay: .zero) }
        }
        .onDisappear {
            state.howlPanelOpen = false
            Task { @MainActor in
                await state.stopHowlaroundDraft()
                if !state.howlRenderWorking { state.exportInProgress = false }
            }
        }
    }

    // MARK: preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                if let url = state.howlDraftURL {
                    DraftPlayer(url: url)
                } else {
                    Text("Rendering the first draft…")
                        .foregroundStyle(.secondary)
                }
                if state.howlDraftWorking {
                    VStack {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Updating draft… \(Int((state.howlDraftProgress * 100).rounded()))%")
                                .font(.caption).monospacedDigit()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(state.howlDraftStatus.isEmpty ? " " : state.howlDraftStatus)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(16)
    }

    // MARK: knobs

    private var knobs: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Video Feedback").font(.headline)
                    Spacer()
                    presetsMenu
                    Button("Reset") { state.resetHowlaround() }
                        .buttonStyle(.borderless)
                }
                Text("A camcorder pointed at the TV that's showing its own picture. Every copy has been through your whole look once more than the one around it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(HowlaroundParam.Group.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.rawValue).font(.callout).bold()
                        ForEach(HowlaroundParam.all.filter { $0.group == group }) { param in
                            HowlaroundControl(param: param)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: presets

    @State private var presetsVersion = 0

    private var presetsMenu: some View {
        let presets = FeedbackPresets.discover()
        return Menu {
            Button("Save Preset…") { savePreset() }
            Button("Load Preset…") { loadPreset() }
            if !presets.isEmpty {
                Divider()
                ForEach(presets) { preset in
                    Button(preset.name) { load(preset.url) }
                }
            }
        } label: {
            Text("Presets")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .id(presetsVersion)          // re-list after a save
        .help("Save the camera's settings as a Video Feedback preset, or load one. They live in their own folder, apart from the look presets.")
    }

    private func savePreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FeedbackPresets.saveFolder()
        panel.nameFieldStringValue = "Video feedback \(timestamp).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.saveFeedbackPreset(to: url)
            presetsVersion += 1
        } catch {
            alert("Couldn't save the preset.", error)
        }
    }

    private func loadPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FeedbackPresets.saveFolder()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        do { try state.loadFeedbackPreset(from: url) } catch { alert("Couldn't load the preset.", error) }
    }

    private func alert(_ message: String, _ error: Error) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = error.localizedDescription
        a.alertStyle = .warning
        a.runModal()
    }

    private var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "dd-MM-yy HH.mm.ss"
        return f.string(from: Date())
    }

    // MARK: footer

    private var isVideo: Bool { state.videoSource != nil }
    @State private var showOutput = false

    /// One pass of the render, in seconds.
    private var lengthSeconds: Double {
        isVideo ? state.effectiveTimelineDuration : state.howlaroundSeconds
    }

    private var footer: some View {
        @Bindable var state = state
        return HStack(spacing: 12) {
            if isVideo {
                Text(String(format: "%.1f s, the whole clip", state.effectiveTimelineDuration))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    Text("Length").font(.callout)
                    NumericField(value: $state.howlaroundSeconds, range: 0.5...60, width: 44)
                    Text("s").font(.caption).foregroundStyle(.secondary)
                }
            }
            // The same export options as the Export popover — the same views,
            // bound to the same settings.
            Button {
                showOutput.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(state.exportSummary)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .popover(isPresented: $showOutput, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Export settings").font(.headline)
                    ExportSizeOptions()
                    ExportVideoOptions(lengthSeconds: lengthSeconds)
                    Text("Shared with the Export button.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(width: 300)
            }
            .help("Format, size and quality for the render — the Export settings, shared with the Export button.")
            Spacer()
            if state.howlRenderWorking {
                ProgressView(value: state.howlRenderProgress).frame(width: 120)
                Text("Rendering…").font(.callout)
            } else if !state.howlRenderStatus.isEmpty {
                Text(state.howlRenderStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let out = state.howlLastOutput, !state.howlRenderWorking {
                Button("Open") { NSWorkspace.shared.open(out) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            }
            if state.howlRenderWorking {
                Button("Cancel") { state.cancelHowlaroundRender() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Button("Render…") { render() }
                .keyboardShortcut(.defaultAction)
                .disabled(state.howlRenderWorking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func render() {
        let format = state.exportFormat
        let panel = NSSavePanel()
        if format.isGIF {
            panel.allowedContentTypes = [.gif]
        } else {
            panel.allowedContentTypes = [format.isProRes ? .quickTimeMovie : .mpeg4Movie]
        }
        panel.nameFieldStringValue = "video feedback \(timestamp).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.renderHowlaroundFile(to: url)
    }
}

/// One camera knob: label, value, slider (double-click the knob for its
/// neutral setting), or a switch. Knobs either side of a middle read in words
/// ("20% right"), and every slider says what its ends mean.
private struct HowlaroundControl: View {
    @Environment(AppState.self) private var state
    let param: HowlaroundParam

    private var value: Binding<Double> {
        Binding(get: { state.howlaroundSettings[param.id] },
                set: { state.setHowlaroundValue(param.id, $0) })
    }

    /// Greyed out while the knob it depends on is off.
    private var idle: Bool {
        let s = state.howlaroundSettings
        switch param.id {
        case "drift_dir": return s["drift"] == 0
        case "seed": return s["shake"] == 0
        default: return false
        }
    }

    var body: some View {
        Group {
            switch param.kind {
            case .toggle:
                Toggle(isOn: Binding(get: { value.wrappedValue >= 0.5 },
                                     set: { value.wrappedValue = $0 ? 1 : 0 })) {
                    Text(param.label).font(.callout)
                }
                .toggleStyle(.switch)
            case .direction:
                direction
            case .slider(let lo, let hi, let percent, let unit, let step):
                slider(lo: lo, hi: hi, percent: percent, unit: unit, step: step)
            }
        }
        .disabled(idle)
        .opacity(idle ? 0.45 : 1)
        .help(param.help)
    }

    private func slider(lo: Double, hi: Double, percent: Bool, unit: String, step: Double?) -> some View {
        let scale = percent ? 100.0 : 1.0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(param.label).font(.callout).lineLimit(1)
                Spacer()
                if param.sides != nil {
                    // The size in the field, the side in words; a negative
                    // number typed in switches sides.
                    let reading = param.reading(value.wrappedValue)
                    NumericField(value: Binding(
                        get: { param.reading(value.wrappedValue).magnitude * scale },
                        set: { typed in
                            let side: Double = value.wrappedValue < 0 ? -1 : 1
                            value.wrappedValue = (typed < 0 ? -side : side) * abs(typed) / scale
                        }),
                        range: 0...(max(abs(lo), abs(hi)) * scale), width: 46)
                    Text(reading.magnitude == 0 ? reading.side : (percent ? "% " : "\(unit) ") + reading.side)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 104, alignment: .leading)
                        .lineLimit(1)
                } else {
                    NumericField(value: Binding(get: { value.wrappedValue * scale },
                                                set: { value.wrappedValue = $0 / scale }),
                                 range: (lo * scale)...(hi * scale), width: 46)
                    Text(percent ? "%" : (unit == "frames" && value.wrappedValue == 1 ? "frame" : unit))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 104, alignment: .leading)
                        .lineLimit(1)
                }
            }
            PropertySlider(value: value, range: lo...hi, step: step, neutral: param.neutralValue)
            if let sides = param.sides {
                endLabels(sides.negative.capitalizedFirst, sides.positive.capitalizedFirst)
            } else if let ends = param.ends {
                endLabels(ends.low, ends.high)
            }
            if param.id == "zoom" {
                Text(copiesCaption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var direction: some View {
        let degrees = value.wrappedValue
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(param.label).font(.callout).lineLimit(1)
                Spacer()
                Image(systemName: "arrow.right")
                    .rotationEffect(.degrees(-degrees))
                    .frame(width: 16)
                Text(HowlaroundParam.compass(degrees))
                    .font(.callout).monospacedDigit()
                    .frame(width: 104, alignment: .leading)
            }
            PropertySlider(value: value, range: 0...360, neutral: param.neutralValue)
            HStack {
                ForEach(Array(["Right", "Up", "Left", "Down", "Right"].enumerated()), id: \.offset) { i, word in
                    Text(word)
                    if i < 4 { Spacer() }
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func endLabels(_ low: String, _ high: String) -> some View {
        HStack {
            Text(low)
            Spacer()
            Text(high)
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private var copiesCaption: String {
        guard state.howlaroundSettings.tvInView else { return "The camera doesn't see the TV — no feedback." }
        guard let n = state.howlaroundCopies else { return "Copies grow instead of shrinking — the feedback swirls." }
        return n >= 200 ? "200+ copies deep" : "≈ \(n) cop\(n == 1 ? "y" : "ies") deep"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Plays the latest draft on a loop, silently.
private struct DraftPlayer: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        var url: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // A scrubber appears on hover: the draft runs the whole render now.
        view.controlsStyle = .minimal
        view.videoGravity = .resizeAspect
        view.player = context.coordinator.player
        context.coordinator.player.isMuted = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let c = context.coordinator
        guard c.url != url else { return }
        c.url = url
        c.looper?.disableLooping()
        c.player.removeAllItems()
        let item = AVPlayerItem(url: url)
        c.looper = AVPlayerLooper(player: c.player, templateItem: item)
        c.player.play()
    }
}
