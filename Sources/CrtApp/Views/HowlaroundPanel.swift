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
        .frame(width: 1040, height: 700)
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
                            Text("Updating draft…").font(.caption)
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
                    Text("Howlaround").font(.headline)
                    Spacer()
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

    // MARK: footer

    private var isVideo: Bool { state.videoSource != nil }

    private var outputSummary: String {
        if state.howlaroundGIF {
            let s = state.exportGifSize
            return "\(s.width) × \(s.height) · \(state.gifFPS) fps"
        }
        let s = state.exportVideoSize
        let codec = (state.exportFormat.codec ?? .h264).rawValue
        return "\(s.width) × \(s.height) · \(codec)"
    }

    private var footer: some View {
        @Bindable var state = state
        return HStack(spacing: 12) {
            Picker("", selection: $state.howlaroundGIF) {
                Text("Video").tag(false)
                Text("GIF").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
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
            Text(outputSummary).font(.callout).foregroundStyle(.secondary)
                .help("Size and format come from the Export settings.")
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
        let gif = state.howlaroundGIF
        let panel = NSSavePanel()
        let ext: String
        if gif {
            panel.allowedContentTypes = [.gif]
            ext = "gif"
        } else {
            let codec = state.exportFormat.codec ?? .h264
            panel.allowedContentTypes = [codec.isProRes ? .quickTimeMovie : .mpeg4Movie]
            ext = codec.fileExtension
        }
        let f = DateFormatter()
        f.dateFormat = "dd-MM-yy HH.mm.ss"
        panel.nameFieldStringValue = "howlaround \(f.string(from: Date())).\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.renderHowlaroundFile(to: url)
    }
}

/// One camera knob: label, value, slider (double-click the knob for its
/// neutral setting), or a switch.
private struct HowlaroundControl: View {
    @Environment(AppState.self) private var state
    let param: HowlaroundParam

    private var value: Binding<Double> {
        Binding(get: { state.howlaroundSettings[param.id] },
                set: { state.setHowlaroundValue(param.id, $0) })
    }

    var body: some View {
        switch param.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { value.wrappedValue >= 0.5 },
                                 set: { value.wrappedValue = $0 ? 1 : 0 })) {
                Text(param.label).font(.callout)
            }
            .toggleStyle(.switch)
            .help(param.help)
        case .slider(let lo, let hi, let percent, let unit, let step):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(param.label).font(.callout).lineLimit(1)
                    Spacer()
                    if percent {
                        NumericField(value: Binding(get: { value.wrappedValue * 100 },
                                                    set: { value.wrappedValue = $0 / 100 }),
                                     range: (lo * 100)...(hi * 100), width: 52)
                        Text("%").font(.caption).foregroundStyle(.secondary)
                            .frame(minWidth: 12, alignment: .leading)
                    } else {
                        NumericField(value: value, range: lo...hi, width: 52)
                        Text(unit).font(.caption).foregroundStyle(.secondary)
                            .frame(minWidth: 12, alignment: .leading)
                    }
                }
                PropertySlider(value: value, range: lo...hi, step: step, neutral: param.neutralValue)
                if param.id == "zoom" {
                    Text(copiesCaption).font(.caption).foregroundStyle(.secondary)
                }
            }
            .help(param.help)
        }
    }

    private var copiesCaption: String {
        guard state.howlaroundSettings.tvInView else { return "The camera doesn't see the TV — no feedback." }
        guard let n = state.howlaroundCopies else { return "The screen overfills the frame: copies grow and swirl." }
        return n >= 200 ? "200+ copies" : "≈ \(n) cop\(n == 1 ? "y" : "ies") visible"
    }
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
        view.controlsStyle = .none
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
