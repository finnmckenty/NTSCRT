import SwiftUI

/// Display-only controls that affect how the preview renders, not the
/// actual exported pixels: zoom + pan, and a "compare" split that lets
/// the user drag a vertical line with shader-on on one side and
/// shader-off on the other.
struct ViewPanel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            Text("View").font(.headline)

            Toggle("Compare (split before/after)", isOn: $state.compareEnabled)
                .toggleStyle(.checkbox)
                .help("Split the preview: full pipeline (downscale + VHS + shader) on the left of the line, the untouched original on the right. Drag the line to move the split.")

            Toggle("Integer scale", isOn: $state.integerScale)
                .toggleStyle(.checkbox)
                .help("Render at a whole-number multiple of the chain input (letterboxed), like RetroArch's Integer Scale. Scanline and beam-shape parameters read much more clearly when every source line maps to the same number of screen pixels.")

            Toggle("Animate", isOn: $state.animatePreview)
                .toggleStyle(.checkbox)
                .disabled(state.exportInProgress)
                .help("Advance the shader frame counter continuously (60 fps). Needed to see frame-based effects like interlacing (CRT Royale) or animated NTSC artifacts (CRT Sim). Off = preview renders only when something changes. PNG export captures the current animation frame.")

            HStack {
                Text("Zoom").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((state.zoom * 100).rounded()))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $state.zoom, in: 1.0...12.0, step: 0.05)

            HStack {
                Button("Reset view") { state.resetView() }
                    .buttonStyle(.borderless)
                    .disabled(state.zoom == 1.0 && state.panX == 0 && state.panY == 0)
                Spacer()
            }

            Text("Hold space to pan when zoomed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
