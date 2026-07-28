import SwiftUI

/// Keyframe timeline docked under the preview (image sources, timeline mode
/// on): a time ruler, a track of master keyframes, and a visible easing
/// dropdown under each one. Keyframe times are normalized, so the duration
/// field rescales the whole animation proportionally.
struct TimelineBar: View {
    @Environment(AppState.self) private var state
    @State private var selectedKey: UUID?

    private let rulerHeight: CGFloat = 28
    private let trackHeight: CGFloat = 92
    private let chipRowHeight: CGFloat = 30
    private let chipTopGap: CGFloat = 10        // breathing room under the track
    private let chipWidth: CGFloat = 92

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            controlsRow
            GeometryReader { geo in
                track(width: max(1, geo.size.width))
            }
            .frame(height: rulerHeight + trackHeight + chipTopGap
                           + chipRowHeight * CGFloat(chipRowCount))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - controls

    private var controlsRow: some View {
        @Bindable var state = state
        return HStack(spacing: 10) {
            Text("ANIMATE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.8)

            Button {
                state.toggleTimelinePreview()
            } label: {
                Image(systemName: (state.timelinePlaying || state.videoPlaying) ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(state.exportInProgress || (state.timelineKeys.isEmpty && state.videoSource == nil))
            .tooltip(state.timelinePlaying ? "Pause"
                     : "Preview the keyframe animation in the preview (loops)")

            Button {
                state.setKeyframeAtPlayhead()
                selectedKey = state.timelineKeys.first { abs($0.t - state.playheadT) < 0.005 }?.id
            } label: {
                Label("Keyframe", systemImage: "stopwatch")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tooltip("Snapshot every VHS + shader parameter at the playhead as a keyframe (updates the keyframe under the playhead). Nothing is keyed until you press this.")

            if let id = selectedKey, state.timelineKeys.contains(where: { $0.id == id }) {
                Button {
                    state.deleteKeyframe(id: id)
                    selectedKey = nil
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tooltip("Delete the selected keyframe")
            }

            Spacer()

            Text(String(format: "%.2f s", state.playheadT * state.effectiveTimelineDuration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider().frame(height: 14)

            if state.videoSource == nil {
                HStack(spacing: 4) {
                    Text("Duration").font(.caption).foregroundStyle(.secondary)
                    NumericField(value: $state.timelineDuration, range: 0.5...600, width: 46)
                    Text("s").font(.caption).foregroundStyle(.secondary)
                }
                .tooltip("Video duration. Keyframes are proportional — changing the duration stretches the whole animation.")

                Picker("", selection: $state.timelineFPS) {
                    Text("12 fps").tag(12)
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .tooltip("Frame rate for the exported video")
            } else {
                // A clip brings its own length and frame rate.
                Text(String(format: "%.2f s  ·  %d fps",
                            state.effectiveTimelineDuration, state.effectiveTimelineFPS))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tooltip("Length and frame rate come from the clip. Keyframes are positioned proportionally along it.")
            }
        }
    }

    // MARK: - ruler + track

    private func track(width w: CGFloat) -> some View {
        let trackMidY = rulerHeight + trackHeight / 2

        return ZStack(alignment: .topLeading) {
            // Scrub surface: ruler + track band only, so the easing menus
            // below stay clickable.
            Rectangle()
                .fill(Color.primary.opacity(0.04))
                .frame(height: rulerHeight + trackHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in state.scrubTimeline(to: Double(v.location.x / w)) }
                )

            ticks(width: w)

            // Track line
            Capsule()
                .fill(Color.primary.opacity(0.18))
                .frame(width: w, height: 5)
                .offset(y: trackMidY - 2.5)
                .allowsHitTesting(false)

            if state.timelineKeys.isEmpty {
                Text("Dial in a look, then press Keyframe to set one")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: w, alignment: .center)
                    .offset(y: trackMidY + 14)
                    .allowsHitTesting(false)
            }

            ForEach(Array(chipRows().enumerated()), id: \.element.key.id) { _, entry in
                easingChip(for: entry.key, width: w, row: entry.row)
            }

            ForEach(state.timelineKeys) { key in
                diamond(for: key, width: w, midY: trackMidY)
            }

            playhead(width: w)
        }
        .coordinateSpace(name: "timeline")
    }

    private func ticks(width w: CGFloat) -> some View {
        // One label per second while they fit; otherwise thin out.
        let duration = state.effectiveTimelineDuration
        let step = max(1.0, (duration / max(1, Double(Int(w / 60)))).rounded(.up))
        let marks = stride(from: 0.0, through: duration, by: step).map { $0 }
        return ForEach(marks, id: \.self) { s in
            let x = CGFloat(s / duration) * w
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "%.0f", s))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 1, height: 5)
            }
            .offset(x: min(max(x, 2), w - 12), y: 0)
            .allowsHitTesting(false)
        }
    }

    private func playhead(width w: CGFloat) -> some View {
        let h = rulerHeight + trackHeight
        let knob: CGFloat = 10
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: h)
            Circle()
                .fill(Color.red)
                .frame(width: knob, height: knob)
                .offset(y: -4)
        }
        // The knob makes this stack `knob` wide, so the offset has to back
        // out half of that — otherwise the line lands right of the playhead
        // time and looks off-centre against a keyframe diamond.
        .frame(width: knob)
        .offset(x: CGFloat(state.playheadT) * w - knob / 2)
        .allowsHitTesting(false)
    }

    private func diamond(for key: Keyframe, width: CGFloat, midY: CGFloat) -> some View {
        let isSelected = selectedKey == key.id
        let hit: CGFloat = 30
        return Image(systemName: "diamond.fill")
            .font(.system(size: isSelected ? 21 : 18))
            .foregroundStyle(isSelected ? Color.accentColor : Color.accentColor.opacity(0.85))
            .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
            .frame(width: hit, height: trackHeight)     // generous hit target
            .contentShape(Rectangle())
            .offset(x: CGFloat(key.t) * width - hit / 2, y: midY - trackHeight / 2)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("timeline"))
                    .onChanged { v in
                        selectedKey = key.id
                        state.moveKeyframe(id: key.id, to: Double(v.location.x / width))
                    }
            )
            .onTapGesture {
                selectedKey = key.id
                state.scrubTimeline(to: key.t)
            }
            .contextMenu {
                Picker("Interpolation", selection: Binding(
                    get: { key.easing },
                    set: { state.setKeyframeEasing(id: key.id, $0) }
                )) {
                    ForEach(KeyEasing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Delete Keyframe", role: .destructive) {
                    state.deleteKeyframe(id: key.id)
                    if selectedKey == key.id { selectedKey = nil }
                }
            }
            .tooltip("Keyframe at \(String(format: "%.2fs", key.t * state.effectiveTimelineDuration)) — drag to move, click to jump here")
    }

    /// Easing dropdown under each keyframe. Chips stagger onto a second row
    /// when neighbours are too close to sit side by side.
    ///
    /// The chip lives in a fixed-width container so it centres on the
    /// keyframe regardless of the label ("Linear" vs "Ease in-out"), and
    /// draws its own chevron — the system menu indicator sits at the
    /// trailing edge and would throw the centring off.
    private func easingChip(for key: Keyframe, width: CGFloat, row: Int) -> some View {
        let y = rulerHeight + trackHeight + chipTopGap + CGFloat(row) * chipRowHeight
        return Menu {
            ForEach(KeyEasing.allCases, id: \.self) { e in
                Button {
                    state.setKeyframeEasing(id: key.id, e)
                } label: {
                    if e == key.easing { Label(e.rawValue, systemImage: "checkmark") }
                    else { Text(e.rawValue) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(key.easing.rawValue)
                    .font(.system(size: 10))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 5))
        }
        // .borderlessButton discards a custom label (it renders its own
        // title + leading indicator), which breaks both the centring and
        // the chip styling — .button keeps the label exactly as authored.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: chipWidth)
        .offset(x: max(0, min(CGFloat(key.t) * width - chipWidth / 2, width - chipWidth)), y: y)
        .tooltip("Interpolation leaving this keyframe")
    }

    /// Chip rows actually in use — the bar only grows a second row when
    /// keyframes sit too close for their dropdowns to fit side by side.
    private var chipRowCount: Int {
        let rows = chipRows()
        guard !rows.isEmpty else { return 1 }
        return (rows.map(\.row).max() ?? 0) + 1
    }

    /// Assign each keyframe's chip to row 0 or 1 so overlapping chips don't
    /// pile up on tightly spaced keys.
    private func chipRows() -> [(key: Keyframe, row: Int)] {
        var out: [(Keyframe, Int)] = []
        var lastRowT: [Double] = [-1, -1]
        // Approximate: the chip is a fixed 92pt and the track is typically
        // 600–1300pt, so this errs toward staggering a little early rather
        // than letting chips overlap in a narrow window.
        let minGap = 0.13
        for key in state.timelineKeys.sorted(by: { $0.t < $1.t }) {
            let row = (key.t - lastRowT[0]) >= minGap ? 0 : 1
            lastRowT[row] = key.t
            out.append((key, row))
        }
        return out.map { (key: $0.0, row: $0.1) }
    }
}
