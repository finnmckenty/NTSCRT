import SwiftUI
import CrtCore

/// Crop the source to an aspect ratio before anything else sees it. The
/// ratio grid follows Midjourney's: square on its own, the portrait shapes
/// above the same shapes in landscape. Picking one turns the crop on; dragging
/// the picture in the preview slides the crop (PreviewView, with the rest of
/// the picture shown dimmed around it meanwhile — CropContextOverlay).
/// Closed by default: it shares the Downscale section and room is short.
struct CropPanel: View {
    @Environment(AppState.self) private var state
    @State private var expanded = false

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Twirl(expanded: $expanded)
                Toggle("Crop", isOn: $state.cropEnabled)
                    .font(.headline)
                    .help("Crop the picture to an aspect ratio before anything else in the chain sees it.")
            }

            if expanded {
                HStack {
                    Text("Aspect ratio").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(state.cropEnabled ? "\(state.cropRatio.width) : \(state.cropRatio.height)" : "Off")
                        .font(.system(.callout, design: .monospaced))
                }
                ratioGrid
                position
                if let size = state.croppedSize, state.cropEnabled {
                    HStack {
                        Spacer()
                        Text("→ \(size.width) × \(size.height)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .help("What the crop leaves of the source, in its pixels.")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: ratios

    private var ratioGrid: some View {
        let gap: CGFloat = 2, row: CGFloat = 28
        return HStack(spacing: gap) {
            tile(.square)
                .frame(width: 58, height: 2 * row + gap)
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    ForEach(SourceCrop.portrait, id: \.self) { tile($0).frame(height: row) }
                }
                HStack(spacing: gap) {
                    ForEach(SourceCrop.landscape, id: \.self) { tile($0).frame(height: row) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func tile(_ ratio: SourceCrop.Ratio) -> some View {
        let selected = state.cropEnabled && state.cropRatio == ratio
        return Button {
            state.cropRatio = ratio
            state.cropEnabled = true
        } label: {
            Text(ratio.label)
                .font(.system(.callout).monospacedDigit())
                .foregroundStyle(selected ? Color(nsColor: .textBackgroundColor) : .primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(selected ? Color.primary.opacity(0.88) : Color.primary.opacity(0.09))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tooltip("Crop to \(ratio.width):\(ratio.height)")
    }

    // MARK: position

    /// How to move the crop — or a note that the picture is already this shape.
    @ViewBuilder private var position: some View {
        if state.cropEnabled, let size = state.sourcePixelSize {
            if SourceCrop(ratio: state.cropRatio).cut(width: size.width, height: size.height) == .none {
                Text("The picture is already this shape — nothing to crop.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Drag the picture to move the crop; double-click it to center.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
